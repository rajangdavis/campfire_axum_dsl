D = "david@37signals.com"
URLS = ["https://github.com/basecamp/once-campfire", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://rubyonrails.org/",
        "https://x.com/dhh/status/1", "https://example.com/", "https://en.wikipedia.org/wiki/Campfire", "http://example.com/",
        "https://example.com/archive.zip", "https://example.com/IMAGE.JPG", "http://127.0.0.1:3101/", "http://10.0.0.1/",
        "http://[::1]/", "not a url", "https://nonexistent.invalid/", "ftp://example.com/", "https://github.com/rails/rails",
        "https://www.ruby-lang.org/en/", "https://basecamp.com/"]
SCENARIOS = [dict(name=f"unfurl/{i}", seed="default", **{"as": D}, bodies=True, reuse=True, steps=[("POST", "/unfurl_link", {"url": u})]) for i, u in enumerate(URLS)]
SCENARIOS.append(dict(name="unfurl/missing_url", seed="default", **{"as": D}, steps=[("POST", "/unfurl_link", {})]))
