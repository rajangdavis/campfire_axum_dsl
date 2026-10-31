fragment do
  # app/models/application_platform.rb (over platform_agent and the useragent gem 0.16.11), as far as the views and
  # allow_browser read it. The gem picks a parser class by the User-Agent's products, in this order, and that decides
  # `user_agent.browser`: a trailing Edge/ token is Edge (a modern Edg/ token is Chrome), a trailing OPR/ or a leading
  # Opera is Opera, any Chrome/ or CriOS/ product is Chrome, any other AppleWebKit agent is Safari (HeadlessChrome is
  # a different product name, so it reads as Safari), and a Gecko agent is Firefox. Not ported: Internet Explorer,
  # Vivaldi, WeChat, iTunes, PlayStation, BlackBerry and the Android stock browser, which the gem names otherwise.
  helper :pwa_browser, args: [:string], returns: :string do |agent|
    return "Edge" if agent.match?(/Edge\/[0-9.]+\s*\z/)
    return "Opera" if agent.match?(/\AOpera/) || agent.match?(/OPR\/[0-9.]+\s*\z/)
    return "Chrome" if agent.match?(/\bChrome\//) || agent.match?(/\bCriOS\//)
    return "Safari" if agent.match?(/AppleWebKit/)
    return "Firefox" if agent.match?(/\bFirefox\//)
    ""
  end

  # ApplicationPlatform#ios?, #android?: a plain match on the header, not on the parsed platform.
  helper :pwa_ios, args: [:string], returns: :bool do |agent|
    agent.match?(/iPhone|iPad/)
  end

  helper :pwa_android, args: [:string], returns: :bool do |agent|
    agent.match?(/Android/)
  end

  # ApplicationPlatform#operating_system. The gem's `platform` is the application comment's first entry (Windows for
  # any entry containing it; Android and CrOS for Chrome and WebKit when any entry has them); a Linux desktop falls
  # through to the gem's `os`, which contains "Linux".
  helper :pwa_os, args: [:string], returns: :string do |agent|
    return "Android" if agent.match?(/Android/)
    return "iPad" if agent.match?(/\(iPad/)
    return "iPhone" if agent.match?(/\(iPhone/)
    return "macOS" if agent.match?(/\(Macintosh/)
    return "Windows" if agent.match?(/\(Windows/) || pwa_browser(agent) == "Edge"
    return "ChromeOS" if agent.match?(/CrOS/)
    return "Linux" if agent.match?(/Linux/)
    ""
  end

  # One flag of the PWA help partials, by name. They are mutually exclusive within each group, as the partials' case
  # statements are, so a view can chain {% if %} blocks without comparisons. `chrome` etc. read pwa_browser.
  helper :pwa_flag, args: [:string, :string], returns: :bool do |agent, which|
    browser = pwa_browser(agent)
    ios = pwa_ios(agent)
    android = pwa_android(agent)
    desktop = !ios && !android
    chrome = browser == "Chrome"
    firefox = browser == "Firefox"
    safari = browser == "Safari"
    edge = browser == "Edge"
    case which
    when "sc_ios" then (safari || chrome) && ios
    when "ff_android" then firefox && android
    when "edge_desktop" then edge && desktop
    when "ff_desktop" then firefox && desktop
    when "chrome_desktop" then chrome && desktop
    when "chrome_android" then chrome && android
    when "safari_desktop" then safari && desktop
    when "ffchrome_desktop" then (firefox || chrome) && desktop
    when "windows" then pwa_os(agent) == "Windows"
    when "install_hidden" then chrome || (firefox && !android)
    when "edge" then edge
    else false
    end
  end

  # One number of a version token: `tail` is the header from just after the product name (a caller cuts it with a
  # literal regex), the token is up to the next space, split on "." (an iOS version is cut on "_" and turned into one).
  helper :pwa_part, args: [:string, :i64], returns: :i64 do |tail, index|
    token = (tail.split.first || "").tr("_", ".")
    part = token.split(".")[index] || ""
    part.to_i
  end

  # ActionController::AllowBrowser with Campfire's VERSIONS (safari 17.2, chrome 120, firefox 121, opera 104): a
  # present, versioned header below the minimum is blocked, unless the gem calls the agent a bot. The version is the
  # gem's: CriOS or Chrome, Firefox, Opera's Version or OPR, Safari's Version, else the iOS version of a WebKit agent;
  # an agent with no such version is never blocked.
  helper :pwa_blocked, args: [:string], returns: :bool do |agent|
    return false if agent.strip.empty?
    return false if agent.match?(/\([^)]*[Bb][Oo][Tt]/) || agent.include?("Chrome-Lighthouse")
    browser = pwa_browser(agent)
    return pwa_part(agent.include?("CriOS/") ? agent.sub(/\A.*?\bCriOS\//, "") : agent.sub(/\A.*?\bChrome\//, ""), 0) < 120 if browser == "Chrome"
    return pwa_part(agent.sub(/\A.*?\bFirefox\//, ""), 0) < 121 if browser == "Firefox"
    return false if browser == "Opera" && !agent.include?("Version/") && !agent.include?("OPR/")
    return pwa_part(agent.include?("Version/") ? agent.sub(/\A.*?\bVersion\//, "") : agent.sub(/\A.*?\bOPR\//, ""), 0) < 104 if browser == "Opera"
    return false if browser != "Safari"
    tail = agent.sub(/\A.*?\bVersion\//, "")
    return pwa_part(tail, 0) < 17 || (pwa_part(tail, 0) == 17 && pwa_part(tail, 1) < 2) if agent.include?("Version/")
    return false unless agent.match?(/(CPU iPhone OS |CPU OS )\d/)
    ios = agent.sub(/\A.*?(CPU iPhone OS |CPU OS )/, "")
    pwa_part(ios, 0) < 17 || (pwa_part(ios, 0) == 17 && pwa_part(ios, 1) < 2)
  end

  # ApplicationPlatform#apple_messages?: Apple Messages spoofs both the Facebook and Twitter bots.
  helper :pwa_apple_messages, args: [:string], returns: :bool do |agent|
    lowered = agent.downcase
    lowered.include?("facebookexternalhit") && lowered.include?("twitterbot")
  end

  # AllowBrowser: `allow_browser versions: VERSIONS, block: -> { render template: "sessions/incompatible_browser" }`,
  # the first filter of ApplicationController, so it is declared after :authenticate (the later layer runs first). The
  # page is 200, titled "Campfire" for Apple Messages link previews (they spoof both the Facebook and Twitter bots).
  # The /up health check, the assets and the public error pages are not controller actions and skip it.
  before :allow_browser do
    return render(:incompatible_browser, locals: { title: pwa_apple_messages(user_agent) ? "Campfire" : "Unsupported browser", vapid_key: setting(:vapid_public_key), logo_version: (account_page || raise("the account was not read back")).logo_version, signed_in: false, user_id: "", user_name: "", flash_on: false, flash_alert: false, flash_text: "" }) if pwa_blocked(user_agent)
    "continue"
  end
end
