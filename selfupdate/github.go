package selfupdate

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Repo 是发布源，形如 owner/name。
//
// 原设计写死为常量，理由是"更新源可配 = 给任何能改配置的人一条远程代码执行通道"。
// 这个安全考量在本 fork 里**原样保留**：Repo 仍然不是运行时配置项，改它只能靠
// 重新编译（ldflags -X），运行时（页面 / .env / 数据库）改不了。
//
// 之所以从 const 改成 var：原值 Autumn-27/artex 的仓库与 Release 已全部 404，
// 写死会让「一键更新」永久失败。改为 var 后由 build.sh 注入各 fork 自己的发布源：
//
//	-ldflags "-X github.com/Autumn-27/artex/selfupdate.Repo=<owner>/<name>"
//
// **零值刻意是空字符串**，表示"没有可用发布源"—— 一键更新被结构性禁用，
// 前端显示「未配置发布源」，而不是拿一个必然 404 的上游仓库当故障报给用户。
// 想恢复原上游行为就显式注入 Autumn-27/artex。
var Repo string

// RepoConfigured 报告当前构建是否带了一个可用的发布源。
// 空串（未注入 / 显式置空）意味着禁用一键更新。
func RepoConfigured() bool {
	return strings.TrimSpace(Repo) != ""
}

// RepoOrDefault 返回用于展示的仓库名，空串时给出一个占位说明。
func RepoOrDefault() string {
	if r := strings.TrimSpace(Repo); r != "" {
		return r
	}
	return "（未配置发布源）"
}

// latestURL 是 GitHub 的"最新正式版"接口。它会自动跳过 prerelease 和 draft。
//
// 刻意在每次调用时拼接而不是做成包级 var：Repo 是可被 ldflags 注入的 var，
// 包级初始化顺序不保证它已被替换，固化的 URL 会指向旧仓库。
func latestURL() string {
	return "https://api.github.com/repos/" + strings.TrimSpace(Repo) + "/releases/latest"
}

// allowedHosts 限定升级链路能访问的域名。配合下面的 checkRedirect，
// 任何一跳被重定向到名单外的主机都会直接失败——这是防止 DNS 污染 / 中间人
// 把二进制换掉的第一道闸门，第二道是 SHA256SUMS 比对。
var allowedHosts = map[string]bool{
	"api.github.com":                       true,
	"github.com":                           true,
	"objects.githubusercontent.com":        true, // release 资产实际落地的对象存储
	"release-assets.githubusercontent.com": true,
	"raw.githubusercontent.com":            true,
}

// Release 是 GitHub Release 里我们关心的字段。
type Release struct {
	TagName     string    `json:"tag_name"`
	Name        string    `json:"name"`
	Body        string    `json:"body"`
	Draft       bool      `json:"draft"`
	Prerelease  bool      `json:"prerelease"`
	PublishedAt time.Time `json:"published_at"`
	HTMLURL     string    `json:"html_url"`
	Assets      []Asset   `json:"assets"`
}

// Asset 是 Release 上挂的一个文件。
type Asset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
	Size int64  `json:"size"`
}

// NewClient 构造一个只认 GitHub 域名的 HTTP 客户端。proxy 为空则直连。
//
// 刻意不复用默认 Transport：升级链路必须强制走 TLS 且校验证书，不能被别处
// 设置的 InsecureSkipVerify 之类影响到。
func NewClient(proxy string) *http.Client {
	tr := &http.Transport{
		ForceAttemptHTTP2:   true,
		TLSHandshakeTimeout: 15 * time.Second,
	}
	if p := strings.TrimSpace(proxy); p != "" {
		if pu, err := url.Parse(p); err == nil {
			tr.Proxy = http.ProxyURL(pu)
		}
	}
	return &http.Client{
		Transport: tr,
		Timeout:   30 * time.Minute, // 下载整包，不能按请求级超时卡死
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return fmt.Errorf("重定向次数过多")
			}
			return checkURL(req.URL)
		},
	}
}

// checkURL 强制 https + 域名白名单。
func checkURL(u *url.URL) error {
	if u.Scheme != "https" {
		return fmt.Errorf("拒绝非 HTTPS 地址: %s", u.Scheme+"://"+u.Host)
	}
	if !allowedHosts[strings.ToLower(u.Hostname())] {
		return fmt.Errorf("拒绝非 GitHub 域名: %s", u.Hostname())
	}
	return nil
}

// FetchLatest 查询最新正式版。
func FetchLatest(ctx context.Context, c *http.Client) (*Release, error) {
	if !RepoConfigured() {
		return nil, fmt.Errorf("本构建未配置发布源（编译时未注入 Repo），一键更新不可用；" +
			"请用 build.sh 重新编译并传入 -ldflags \"-X github.com/Autumn-27/artex/selfupdate.Repo=<owner>/<name>\"")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, latestURL(), nil)
	if err != nil {
		return nil, err
	}
	if err := checkURL(req.URL); err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "artex-selfupdate")

	resp, err := c.Do(req)
	if err != nil {
		return nil, fmt.Errorf("访问 GitHub 失败（可在系统设置里配置全局代理）: %w", err)
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode == http.StatusForbidden, resp.StatusCode == http.StatusTooManyRequests:
		// 未认证的 GitHub API 是每 IP 每小时 60 次，共用出口 IP 时很容易撞上。
		return nil, fmt.Errorf("GitHub 接口限流（每小时 60 次），请稍后再试")
	case resp.StatusCode == http.StatusNotFound:
		return nil, fmt.Errorf("仓库 %s 尚未发布任何正式版本（该仓库不存在，或已删除 / 未建Release）", RepoOrDefault())
	case resp.StatusCode != http.StatusOK:
		return nil, fmt.Errorf("GitHub 返回 %d", resp.StatusCode)
	}

	var rel Release
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return nil, fmt.Errorf("解析 Release 失败: %w", err)
	}
	if strings.TrimSpace(rel.TagName) == "" {
		return nil, fmt.Errorf("Release 缺少 tag")
	}
	return &rel, nil
}

// AssetName 返回当前平台对应的发布包名，与 build.sh 的 package_binary 保持一致：
// artex-<版本>-<os>-<arch>.zip（版本号不带 v 前缀）。
func AssetName(tag, goos, goarch string) string {
	return fmt.Sprintf("artex-%s-%s-%s.zip", strings.TrimPrefix(tag, "v"), goos, goarch)
}

// FindAsset 在 Release 里按名字找资产。
func (r *Release) FindAsset(name string) (Asset, bool) {
	for _, a := range r.Assets {
		if strings.EqualFold(a.Name, name) {
			return a, true
		}
	}
	return Asset{}, false
}
