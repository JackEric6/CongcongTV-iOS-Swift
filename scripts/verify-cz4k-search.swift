import Foundation

@main
struct VerifyCz4kSearch {
    static func main() {
        let baseURL = URL(string: "https://www.cz4k.com/nimasile?q=%E6%8A%93%E7%89%B9%E5%8A%A1")!
        let html = #"""
        <!doctype html>
        <html><head><title>抓特务 搜索结果</title></head><body>
          <a title="播放" href="/detail/grab-2023.html">播放</a>
          <div class="module-search-item">
            <a href=/detail/grab-2023.html><img data-src="//img.cz4k.com/grab.jpg" alt="抓特务"></a>
            <a class="module-item-title" href="/detail/grab-2023.html">抓特务</a>
          </div>
          <a href="/content/grab-special"><h3>抓特务 特别篇</h3></a>
          <a href="https://cz4k.com/detail/root-domain.html"><h3>抓特务 根域结果</h3></a>
          <a href="javascript:void(0)" data-href="/detail/from-data.html"><h3>抓特务 动态卡片</h3></a>
          <a href="/vod-play/123-1-1.html">播放</a>
          <a href="https://example.net/detail/not-ours.html">抓特务</a>
          <a href="/type/1.html">抓特务分类</a>
        </body></html>
        """#

        let results = Cz4kSearchParser.parse(html: html, baseURL: baseURL)
        precondition(results.count == 4, "expected 4 results, got \(results.count)")
        precondition(results[0].id == "/detail/grab-2023.html")
        precondition(results[0].name == "抓特务")
        precondition(results[0].pic == "https://img.cz4k.com/grab.jpg")
        precondition(results[0].sourceKey == "cz4k")
        precondition(results[1].id == "/content/grab-special")
        precondition(results[1].name == "抓特务 特别篇")
        precondition(results[2].id == "/detail/root-domain.html")
        precondition(results[3].id == "/detail/from-data.html")
        print("CZ4K SEARCH PARSER CHECKS PASSED")
    }
}
