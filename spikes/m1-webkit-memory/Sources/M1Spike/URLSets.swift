import Foundation

enum URLSets {

    /// Deterministic local fixtures. `anim` pages carry a page-world rAF canvas
    /// animation plus a CSS keyframe animation; the rest are static but heavy
    /// (real Bootstrap CSS, real highlight.js/marked/lodash, 300 KB PNGs,
    /// 1.5k-6k DOM nodes).
    ///
    /// Spread across 20 loopback ports (8801..8820) to probe whether WebKit's
    /// process-per-site coalescing keys on port as well as host.
    static func fixtures(count: Int, basePort: Int = 8801, ports: Int = 20) -> [URL] {
        let animIndices: Set<Int> = [1, 5, 50, 99]
        let kinds = ["doc", "feed", "repo"]
        var out: [URL] = []
        for i in 0..<count {
            let port = basePort + (i % ports)
            let kind = animIndices.contains(i) ? "anim" : kinds[i % kinds.count]
            out.append(URL(string: "http://127.0.0.1:\(port)/\(kind)/\(i)")!)
        }
        return out
    }

    static let animIndices: Set<Int> = [1, 5, 50, 99]

    /// 100 real pages across ~60 distinct registrable domains: documentation,
    /// GitHub, news/reference. Chosen to look like Scott's actual working set.
    /// Index 1, 5, 50, 99 are replaced by local `anim` fixtures so that the
    /// rendering-suspension test stays deterministic even in real mode.
    static let real: [String] = [
        "https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame",
        "ANIM",
        "https://developer.apple.com/documentation/webkit/wkwebview",
        "https://github.com/apple/swift",
        "https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html",
        "ANIM",
        "https://news.ycombinator.com/",
        "https://developer.mozilla.org/en-US/docs/Web/CSS/grid-template-areas",
        "https://github.com/rust-lang/rust",
        "https://docs.python.org/3/library/asyncio-task.html",
        "https://www.sqlite.org/lang_select.html",
        "https://developer.apple.com/documentation/appkit/nsscrollview",
        "https://github.com/tokio-rs/tokio",
        "https://doc.rust-lang.org/std/vec/struct.Vec.html",
        "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise",
        "https://kubernetes.io/docs/concepts/workloads/pods/",
        "https://github.com/kubernetes/kubernetes",
        "https://docs.docker.com/engine/reference/builder/",
        "https://www.postgresql.org/docs/current/queries-with.html",
        "https://redis.io/docs/latest/commands/set/",
        "https://en.wikipedia.org/wiki/WebKit",
        "https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cache-Control",
        "https://github.com/microsoft/vscode",
        "https://swiftpackageindex.com/",
        "https://www.swift.org/documentation/",
        "https://docs.rs/serde/latest/serde/",
        "https://crates.io/",
        "https://github.com/facebook/react",
        "https://react.dev/reference/react/useEffect",
        "https://vitejs.dev/guide/",
        "https://developers.cloudflare.com/workers/",
        "https://developers.cloudflare.com/durable-objects/",
        "https://hono.dev/docs/",
        "https://bun.sh/docs",
        "https://nodejs.org/api/fs.html",
        "https://docs.astro.build/en/guides/routing/",
        "https://tailwindcss.com/docs/flex",
        "https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API",
        "https://www.rfc-editor.org/rfc/rfc9110.html",
        "https://httpwg.org/specs/rfc9113.html",
        "https://lobste.rs/",
        "https://arstechnica.com/",
        "https://www.theverge.com/",
        "https://techcrunch.com/",
        "https://www.bbc.com/news",
        "https://apnews.com/",
        "https://www.reuters.com/technology/",
        "https://stackoverflow.com/questions/tagged/swift",
        "https://superuser.com/",
        "https://serverfault.com/",
        "ANIM",
        "https://github.com/ggerganov/llama.cpp",
        "https://huggingface.co/docs/transformers/index",
        "https://pytorch.org/docs/stable/generated/torch.nn.Linear.html",
        "https://numpy.org/doc/stable/reference/generated/numpy.einsum.html",
        "https://pandas.pydata.org/docs/reference/api/pandas.DataFrame.groupby.html",
        "https://docs.astral.sh/uv/",
        "https://docs.astral.sh/ruff/rules/",
        "https://github.com/astral-sh/uv",
        "https://peps.python.org/pep-0008/",
        "https://go.dev/ref/spec",
        "https://pkg.go.dev/net/http",
        "https://github.com/golang/go",
        "https://clang.llvm.org/docs/UsersManual.html",
        "https://llvm.org/docs/LangRef.html",
        "https://man7.org/linux/man-pages/man2/mmap.2.html",
        "https://www.gnu.org/software/bash/manual/bash.html",
        "https://tldp.org/LDP/abs/html/",
        "https://git-scm.com/docs/git-rebase",
        "https://github.com/git/git",
        "https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions",
        "https://developer.mozilla.org/en-US/docs/Web/API/IntersectionObserver",
        "https://web.dev/articles/vitals",
        "https://caniuse.com/",
        "https://developer.apple.com/documentation/swiftui/view",
        "https://developer.apple.com/documentation/foundation/urlsession",
        "https://developer.apple.com/design/human-interface-guidelines/",
        "https://github.com/migueldeicaza/SwiftTerm",
        "https://github.com/mozilla/uniffi-rs",
        "https://mozilla.github.io/uniffi-rs/latest/",
        "https://doc.rust-lang.org/cargo/reference/manifest.html",
        "https://tokio.rs/tokio/tutorial",
        "https://sqlite.org/wal.html",
        "https://www.sqlite.org/fts5.html",
        "https://duckdb.org/docs/sql/introduction",
        "https://clickhouse.com/docs/en/sql-reference/statements/select",
        "https://trino.io/docs/current/sql/select.html",
        "https://spark.apache.org/docs/latest/sql-programming-guide.html",
        "https://cloud.google.com/bigquery/docs/reference/standard-sql/query-syntax",
        "https://docs.snowflake.com/en/sql-reference/constructs",
        "https://dbt-docs.getdbt.com/",
        "https://www.getdbt.com/",
        "https://airflow.apache.org/docs/apache-airflow/stable/index.html",
        "https://prefect.io/",
        "https://grafana.com/docs/grafana/latest/",
        "https://prometheus.io/docs/prometheus/latest/querying/basics/",
        "https://opentelemetry.io/docs/",
        "https://www.elastic.co/guide/en/elasticsearch/reference/current/query-dsl.html",
        "https://nginx.org/en/docs/http/ngx_http_core_module.html",
        "ANIM",
    ]

    static func realURLs(count: Int, basePort: Int = 8801) -> [URL] {
        var out: [URL] = []
        for i in 0..<count {
            let s = real[i % real.count]
            if s == "ANIM" {
                out.append(URL(string: "http://127.0.0.1:\(basePort + (i % 20))/anim/\(i)")!)
            } else {
                out.append(URL(string: s)!)
            }
        }
        return out
    }
}
