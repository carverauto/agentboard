defmodule Agentboard.FrontendAuthTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Agentboard.FrontendAuth
  alias Agentboard.FrontendAuth.{Keys, Sessions}
  alias AgentboardWeb.{Endpoint, FrontendAuthLive}
  alias AgentboardWeb.Plugs.FrontendAuth, as: Gate
  alias Phoenix.LiveView.Lifecycle

  setup_all do
    Application.ensure_all_started(:jose)
    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:phoenix_live_view)
    %{key: JOSE.JWK.generate_key({:rsa, 2048}), other_key: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup %{key: key} do
    previous = Application.get_env(:agentboard, :frontend_auth)

    file =
      Path.join(
        System.tmp_dir!(),
        "agentboard-public-jwks-#{System.unique_integer([:positive])}.json"
      )

    public =
      key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", "fixture")

    File.write!(file, Jason.encode!(%{"keys" => [public]}))

    options = [
      mode: "cloudflare_access",
      issuer: "https://example.cloudflareaccess.com",
      audience: "board-audience",
      jwks_file: file,
      allowed_emails: ["human@example.com"],
      allowed_subjects: [],
      session_ttl_seconds: 300
    ]

    Application.put_env(:agentboard, :frontend_auth, options)
    start_supervised!({Phoenix.PubSub, name: Agentboard.PubSub})
    start_supervised!(Sessions)
    {:ok, config} = FrontendAuth.config()
    now = System.system_time(:second)

    claims = %{
      "iss" => config.issuer,
      "aud" => [config.audience],
      "type" => "app",
      "sub" => "human-id",
      "email" => "human@example.com",
      "iat" => now - 1,
      "nbf" => now - 1,
      "exp" => now + 600
    }

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agentboard, :frontend_auth, previous),
        else: Application.delete_env(:agentboard, :frontend_auth)

      File.rm(file)
    end)

    %{config: config, options: options, jwks_file: file, public: public, claims: claims, now: now}
  end

  test "valid cryptographic human assertion is allowlisted without captain authority", ctx do
    assert {:ok, principal} = FrontendAuth.verify(sign(ctx.key, ctx.claims), ctx.config, ctx.now)
    assert principal.subject == "human-id"
    refute Map.has_key?(principal, :captain)

    assert {:ok, _} =
             FrontendAuth.verify(sign(ctx.key, Map.delete(ctx.claims, "nbf")), ctx.config)
  end

  test "signature, issuer, audience, type and time failures are rejected", ctx do
    assert {:error, :unauthorized} =
             FrontendAuth.verify(sign(ctx.other_key, ctx.claims), ctx.config)

    for replacement <- [
          %{"iss" => "https://attacker.cloudflareaccess.com"},
          %{"aud" => ["another-app"]},
          %{"aud" => [ctx.config.audience, 1]},
          %{"type" => "org"},
          %{"exp" => ctx.now},
          %{"exp" => "9999999999"},
          %{"iat" => ctx.now + 100},
          %{"iat" => nil},
          %{"nbf" => ctx.now + 100},
          %{"nbf" => "0"}
        ] do
      assert {:error, :unauthorized} =
               FrontendAuth.verify(sign(ctx.key, Map.merge(ctx.claims, replacement)), ctx.config)
    end
  end

  test "algorithm confusion, missing or unknown kid and attacker key URLs are rejected", ctx do
    for header <- [
          %{"alg" => "RS256"},
          %{"alg" => "RS256", "kid" => "other"},
          %{"alg" => "RS256", "kid" => "fixture", "jku" => "https://attacker.invalid/keys"},
          %{"alg" => "RS256", "kid" => "fixture", "x5u" => "https://attacker.invalid/keys"},
          %{"alg" => "RS256", "kid" => "fixture", "crit" => ["unknown"]}
        ] do
      assert {:error, :unauthorized} =
               FrontendAuth.verify(sign(ctx.key, ctx.claims, header), ctx.config)
    end

    hmac = JOSE.JWK.from_oct("not-a-public-RSA-key")

    assert {:error, :unauthorized} =
             FrontendAuth.verify(
               sign(hmac, ctx.claims, %{"alg" => "HS256", "kid" => "fixture"}),
               ctx.config
             )

    assert {:error, :unauthorized} = FrontendAuth.verify("a.b.c", ctx.config)

    assert {:error, :unauthorized} =
             FrontendAuth.verify(String.duplicate("a", 16_385), ctx.config)
  end

  test "only explicitly allowed humans pass; service-token claims never do", ctx do
    assert {:error, :forbidden} =
             FrontendAuth.verify(
               sign(ctx.key, %{ctx.claims | "email" => "other@example.com"}),
               ctx.config
             )

    subject_config = %{ctx.config | allowed_emails: [], allowed_subjects: ["human-id"]}
    assert {:ok, _} = FrontendAuth.verify(sign(ctx.key, ctx.claims), subject_config)

    for changes <- [
          %{"sub" => ""},
          %{"email" => ""},
          %{"email" => nil},
          %{"common_name" => "service.access"},
          %{"service_token_id" => "service"},
          %{"service_token_status" => true}
        ] do
      assert {:error, :unauthorized} =
               FrontendAuth.verify(sign(ctx.key, Map.merge(ctx.claims, changes)), ctx.config)
    end
  end

  test "configuration cannot select arbitrary issuer hosts, empty allowlists or unbounded TTL",
       ctx do
    for changes <- [
          [mode: "typo"],
          [issuer: "http://example.cloudflareaccess.com"],
          [issuer: "https://example.cloudflareaccess.com.attacker.invalid"],
          [issuer: "https://example.cloudflareaccess.com/"],
          [issuer: "https://example.cloudflareaccess.com:8443"],
          [jwks_file: "relative.json"],
          [audience: ""],
          [allowed_emails: [], allowed_subjects: []],
          [session_ttl_seconds: 301],
          [session_ttl_seconds: 0]
        ] do
      assert {:error, :misconfigured} =
               FrontendAuth.validate_config(Keyword.merge(ctx.options, changes))
    end
  end

  test "bounded JWKS file fails closed on invalid keys, duplicate kids, removal or oversize",
       ctx do
    token = sign(ctx.key, ctx.claims)
    assert {:ok, _} = FrontendAuth.verify(token, ctx.config)

    for keys <- [
          [ctx.public, ctx.public],
          [Map.put(ctx.public, "d", "private")],
          [Map.put(ctx.public, "alg", "HS256")],
          [Map.put(ctx.public, "n", "AQ")]
        ] do
      File.write!(ctx.jwks_file, Jason.encode!(%{"keys" => keys}))
      assert {:error, :unavailable} = FrontendAuth.verify(token, ctx.config)
    end

    File.write!(ctx.jwks_file, String.duplicate(" ", 65_537))
    assert {:error, :keys_unavailable} = Keys.fetch(ctx.jwks_file, "fixture")
    File.rm!(ctx.jwks_file)
    assert {:error, :unavailable} = FrontendAuth.verify(token, ctx.config)
  end

  test "on mode rejects missing, duplicate and spoofed identity headers", ctx do
    assert Gate.call(http(), []).status == 401

    assert Gate.call(
             http() |> put_req_header("cf-access-authenticated-user-email", "human@example.com"),
             []
           ).status == 401

    token = sign(ctx.key, ctx.claims)

    duplicate = %{
      http()
      | req_headers: [{"cf-access-jwt-assertion", token}, {"cf-access-jwt-assertion", token}]
    }

    assert Gate.call(duplicate, []).status == 401
    assert Gate.call(http() |> put_req_header("cf-access-jwt-assertion", "invalid"), []).halted
  end

  test "HTTP always requires fresh assertion even with valid bridge cookie", ctx do
    conn = authenticate(ctx)
    id = get_session(conn, :frontend_auth_id)
    assert {:ok, _} = Sessions.validate(id)
    refute get_session(conn, :captain)

    cookie =
      conn |> send_resp(200, "ok") |> Map.fetch!(:resp_cookies) |> Map.fetch!("_agentboard")

    assert cookie.secure and cookie.http_only and cookie.same_site == "Lax"
    refute String.contains?(cookie.value, "human@example.com")

    denied = http(cookie.value) |> Gate.call([])
    assert denied.status == 401
    assert {:error, :unauthorized} = Sessions.validate(id)
  end

  test "active same-human bridge does not slide and preserves separate captain proof", ctx do
    conn = authenticate(ctx) |> put_session(:captain, "separate-proof")
    id = get_session(conn, :frontend_auth_id)
    {:ok, original} = Sessions.validate(id)
    conn = Gate.call(conn, [])
    assert get_session(conn, :captain) == "separate-proof"
    assert get_session(conn, :frontend_auth_id) == id
    assert {:ok, ^original} = Sessions.validate(id)
    assert original.expires_at <= ctx.now + 300
    assert original.expires_at <= ctx.claims["exp"]
  end

  test "changing human clears captain proof and revokes old bridge", ctx do
    conn = authenticate(ctx) |> put_session(:captain, "separate-proof")
    id = get_session(conn, :frontend_auth_id)
    changed = %{ctx.claims | "sub" => "another-human"}

    conn =
      conn |> put_req_header("cf-access-jwt-assertion", sign(ctx.key, changed)) |> Gate.call([])

    refute get_session(conn, :captain)
    refute get_session(conn, :frontend_auth_id) == id
    assert {:error, :unauthorized} = Sessions.validate(id)
  end

  test "disconnected mount and reconnect require a registered, unexpired bridge", ctx do
    assert_redirect(FrontendAuthLive.on_mount(:default, %{}, %{}, socket()))

    assert_redirect(
      FrontendAuthLive.on_mount(
        :default,
        %{},
        %{"frontend_auth_id" => String.duplicate("a", 43)},
        socket()
      )
    )

    conn = authenticate(ctx)
    session = get_session(conn)
    assert {:cont, _} = FrontendAuthLive.on_mount(:default, %{}, session, socket())
    assert {:cont, live} = FrontendAuthLive.on_mount(:default, %{}, session, socket(true))
    assert live.assigns.frontend_identity.subject == "human-id"
    assert {:cont, _} = Lifecycle.handle_event("anything", %{}, live)
    assert {:cont, _} = Lifecycle.handle_params(%{}, "https://example.invalid/", live)
    assert {:cont, _} = Lifecycle.handle_info(:refresh, live)

    Gate.revoke_session(conn)
    assert_receive :frontend_auth_revoked
    assert_redirect(FrontendAuthLive.on_mount(:default, %{}, session, socket(true)))
    assert_redirect(Lifecycle.handle_event("save", %{}, live))
    assert_redirect(Lifecycle.handle_params(%{}, "/", live))
    assert_redirect(Lifecycle.handle_info(:refresh, live))
  end

  test "expired bridge blocks events, parameters, PubSub disclosure and reconnect", ctx do
    {:ok, principal} = FrontendAuth.verify(sign(ctx.key, ctx.claims), ctx.config)
    {:ok, id, _} = Sessions.issue(principal, ctx.config)

    assert {:cont, live} =
             FrontendAuthLive.on_mount(:default, %{}, %{"frontend_auth_id" => id}, socket())

    :sys.replace_state(Sessions, fn state -> put_in(state, [id, :expires_at], ctx.now - 1) end)
    assert_redirect(Lifecycle.handle_event("save", %{}, live))
    assert_redirect(Lifecycle.handle_params(%{}, "/", live))
    assert_redirect(Lifecycle.handle_info(:refresh, live))
    assert_redirect(Lifecycle.handle_info(:frontend_auth_expired, live))

    assert_redirect(
      FrontendAuthLive.on_mount(:default, %{}, %{"frontend_auth_id" => id}, socket(true))
    )
  end

  test "short JWT expiry caps bridge lifetime, and real expiry timer is armed", ctx do
    claims = %{ctx.claims | "exp" => System.system_time(:second) + 1}
    {:ok, principal} = FrontendAuth.verify(sign(ctx.key, claims), ctx.config)
    {:ok, id, bridge} = Sessions.issue(principal, ctx.config)
    assert bridge.expires_at == claims["exp"]

    assert {:cont, live} =
             FrontendAuthLive.on_mount(:default, %{}, %{"frontend_auth_id" => id}, socket(true))

    assert_receive :frontend_auth_expired, 1500
    assert_redirect(Lifecycle.handle_info(:frontend_auth_expired, live))
  end

  test "allowlist changes and registry restart invalidate existing bridges", ctx do
    id = authenticate(ctx) |> get_session(:frontend_auth_id)

    Application.put_env(
      :agentboard,
      :frontend_auth,
      Keyword.put(ctx.options, :allowed_emails, ["new@example.com"])
    )

    assert {:error, :unauthorized} = Sessions.validate(id)
    Application.put_env(:agentboard, :frontend_auth, ctx.options)
    id = authenticate(ctx) |> get_session(:frontend_auth_id)
    stop_supervised!(Sessions)
    assert {:error, :unavailable} = Sessions.validate(id)
    start_supervised!(Sessions)
    assert {:error, :unauthorized} = Sessions.validate(id)
  end

  test "logout clears captain and blocks copied old cookies and connected sockets", ctx do
    conn = authenticate(ctx) |> put_session(:captain, "separate-proof")
    session = get_session(conn)
    assert {:cont, live} = FrontendAuthLive.on_mount(:default, %{}, session, socket(true))

    cookie =
      conn |> send_resp(200, "ok") |> Map.fetch!(:resp_cookies) |> Map.fetch!("_agentboard")

    conn =
      http(cookie.value)
      |> put_req_header("cf-access-jwt-assertion", sign(ctx.key, ctx.claims))
      |> Gate.call([])

    logout = AgentboardWeb.FrontendAuthController.logout(conn, %{})
    assert get_resp_header(logout, "location") == ["/cdn-cgi/access/logout"]
    refute get_session(logout, :captain)
    refute get_session(logout, :frontend_auth_id)
    assert_redirect(Lifecycle.handle_event("save", %{}, live))
    replay = http(cookie.value) |> get_session()
    assert_redirect(FrontendAuthLive.on_mount(:default, %{}, replay, socket(true)))
  end

  test "tampered encrypted session cannot mint a LiveView bridge", ctx do
    conn = authenticate(ctx) |> send_resp(200, "ok")
    cookie = conn.resp_cookies["_agentboard"].value <> "x"

    assert_redirect(
      FrontendAuthLive.on_mount(:default, %{}, get_session(http(cookie)), socket(true))
    )
  end

  test "every browser and document route rejects anonymous direct HTTP", _ctx do
    previous = Application.get_env(:agentboard, :rate_limits)

    Application.put_env(:agentboard, :rate_limits,
      ip: 1000,
      agent: 1000,
      window_ms: 60_000,
      max_buckets: 20_000
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agentboard, :rate_limits, previous),
        else: Application.delete_env(:agentboard, :rate_limits)
    end)

    start_supervised!(Agentboard.RateLimits.Owner)

    for path <-
          ~w(/ /tasks/example /prs /prs/example /agents /messages /quota /context /context/example /archive /settings /auth/reauthenticate /documents/example /documents/example/html /documents/example/download) do
      conn = http(nil, path) |> route()
      assert conn.status == 401, "unguarded route: #{path}"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "captain controls and logout keep CSRF protection after successful authentication", ctx do
    for path <- ~w(/settings/unlock /settings/lock /settings/agent-tokens/issue /auth/logout) do
      conn =
        http(nil, path, :post)
        |> put_req_header("cf-access-jwt-assertion", sign(ctx.key, ctx.claims))

      error = assert_raise Plug.Conn.WrapperError, fn -> route(conn) end
      assert %Plug.CSRFProtection.InvalidCSRFTokenError{} = error.reason
    end
  end

  test "captain unlock rotates old bridge and new captain survives following HTTP", ctx do
    previous = Application.get_env(:agentboard, :captain_token)
    Application.put_env(:agentboard, :captain_token, "test-only-captain-token-32-characters")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agentboard, :captain_token, previous),
        else: Application.delete_env(:agentboard, :captain_token)
    end)

    conn = authenticate(ctx)
    old_id = get_session(conn, :frontend_auth_id)

    unlocked =
      AgentboardWeb.CaptainController.unlock(conn, %{
        "token" => "test-only-captain-token-32-characters"
      })

    new_id = get_session(unlocked, :frontend_auth_id)
    assert old_id != new_id
    assert {:error, :unauthorized} = Sessions.validate(old_id)
    assert {:ok, _} = Sessions.validate(new_id)
    assert Agentboard.Captain.authorized?(get_session(unlocked, :captain))
    cookie = unlocked.resp_cookies["_agentboard"].value

    reload =
      http(cookie)
      |> put_req_header("cf-access-jwt-assertion", sign(ctx.key, ctx.claims))
      |> Gate.call([])

    assert get_session(reload, :frontend_auth_id) == new_id
    assert Agentboard.Captain.authorized?(get_session(reload, :captain))
    locked = AgentboardWeb.CaptainController.lock(reload, %{})
    refute get_session(locked, :captain)
    assert {:error, :unauthorized} = Sessions.validate(new_id)
  end

  test "capacity rejects new sessions rather than evicting active authentication", ctx do
    {:ok, principal} = FrontendAuth.verify(sign(ctx.key, ctx.claims), ctx.config)
    {:ok, _, bridge} = Sessions.issue(principal, ctx.config)
    :sys.replace_state(Sessions, fn _ -> Map.new(1..10_000, &{Integer.to_string(&1), bridge}) end)
    assert {:error, :unavailable} = Sessions.issue(principal, ctx.config)

    :sys.replace_state(Sessions, fn sessions ->
      Map.new(sessions, fn {id, value} -> {id, %{value | expires_at: ctx.now - 1}} end)
    end)

    assert {:ok, _, _} = Sessions.issue(principal, ctx.config)
  end

  test "enabled startup rejects unavailable public keys", ctx do
    File.rm!(ctx.jwks_file)
    assert {:stop, :invalid_frontend_auth_configuration} = Sessions.init([])
  end

  test "off mode preserves ordinary local browser access; unknown mode fails closed", ctx do
    Application.put_env(:agentboard, :frontend_auth, mode: "off")
    refute Gate.call(http(), []).halted
    assert {:cont, _} = FrontendAuthLive.on_mount(:default, %{}, %{}, socket())
    refute Endpoint.session_options()[:secure]
    Application.put_env(:agentboard, :frontend_auth, Keyword.put(ctx.options, :mode, "typo"))
    assert Gate.call(http(), []).status == 503
    assert_redirect(FrontendAuthLive.on_mount(:default, %{}, %{}, socket()))
  end

  defp sign(key, claims, header \\ %{"alg" => "RS256", "kid" => "fixture", "typ" => "JWT"}) do
    key |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact() |> elem(1)
  end

  defp http(cookie \\ nil, path \\ "/", method \\ :get) do
    conn =
      conn(method, path) |> Map.put(:secret_key_base, String.duplicate("test-only-secret-", 8))

    conn = if cookie, do: put_req_header(conn, "cookie", "_agentboard=" <> cookie), else: conn
    conn |> Plug.Session.call(Plug.Session.init(Endpoint.session_options())) |> fetch_session()
  end

  defp route(conn),
    do:
      conn
      |> put_private(:phoenix_endpoint, Endpoint)
      |> AgentboardWeb.Router.call(AgentboardWeb.Router.init([]))

  defp authenticate(ctx),
    do:
      http()
      |> put_req_header("cf-access-jwt-assertion", sign(ctx.key, ctx.claims))
      |> Gate.call([])

  defp socket(connected \\ false) do
    %Phoenix.LiveView.Socket{
      router: AgentboardWeb.Router,
      endpoint: Endpoint,
      transport_pid: if(connected, do: self()),
      assigns: %{__changed__: %{}},
      private: %{lifecycle: %Lifecycle{}}
    }
  end

  defp assert_redirect({:halt, socket}) do
    assert {:redirect, %{to: "/auth/reauthenticate"}} = socket.redirected
  end
end
