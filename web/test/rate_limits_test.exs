defmodule Agentboard.RateLimitsTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Agentboard.RateLimits

  setup context do
    previous = Application.get_env(:agentboard, :rate_limits)

    config = [
      ip: 120,
      agent: 60,
      window_ms: 60_000,
      max_buckets: 20_000,
      watch_ip: 20,
      watch_agent: 5,
      max_watches: 1_000
    ]

    config = Keyword.merge(config, Map.get(context, :limits, []))
    Application.put_env(:agentboard, :rate_limits, config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agentboard, :rate_limits, previous),
        else: Application.delete_env(:agentboard, :rate_limits)
    end)

    start_supervised!(RateLimits.Owner)
    :ok
  end

  test "concurrent callers get exactly the configured agent allowance" do
    outcomes =
      1..100
      |> Task.async_stream(fn n -> RateLimits.check({127, 0, 0, n}, "worker") end,
        max_concurrency: 50,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(outcomes, &(&1 == :ok)) == 60
    assert Enum.count(outcomes, &match?({:error, :rate_limited, _}, &1)) == 40
  end

  test "anonymous and changing-agent traffic still hits the IP limit" do
    for n <- 1..120, do: assert(:ok == RateLimits.check({127, 0, 0, 1}, "agent-#{n}"))
    assert {:error, :rate_limited, seconds} = RateLimits.check({127, 0, 0, 1}, nil)
    assert seconds >= 1
  end

  test "429 halts before JSON parsing and ignores spoofed forwarded IP" do
    for _ <- 1..120, do: assert(:ok == RateLimits.check({127, 0, 0, 1}, nil))

    conn =
      Plug.Test.conn(:post, "/api/v1/tasks", "malformed-json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-forwarded-for", "10.0.0.99")
      |> AgentboardWeb.Plugs.RateLimit.call([])

    assert conn.status == 429
    assert conn.halted
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert [delay] = get_resp_header(conn, "retry-after")
    assert String.to_integer(delay) >= 1
    assert %{"error" => %{"code" => "rate_limited"}} = Jason.decode!(conn.resp_body)
    assert conn.body_params == %Plug.Conn.Unfetched{aspect: :body_params}
  end

  test "limiter outage fails closed while process health is independent" do
    stop_supervised!(RateLimits.Owner)
    conn = Plug.Test.conn(:get, "/api/v1/meta") |> AgentboardWeb.Plugs.RateLimit.call([])
    assert conn.status == 503
    assert conn.halted
    live = AgentboardWeb.HealthController.live(Plug.Test.conn(:get, "/health/live"), %{})
    assert live.status == 200
  end

  test "watch reservations enforce capacity and release idempotently" do
    references =
      for _ <- 1..5 do
        assert {:ok, reference} = RateLimits.reserve_watch({127, 0, 0, 1}, "worker")
        reference
      end

    assert {:error, :rate_limited, 1} = RateLimits.reserve_watch({127, 0, 0, 1}, "worker")
    assert :ok = RateLimits.release_watch(hd(references))
    assert :ok = RateLimits.release_watch(hd(references))
    assert {:ok, _} = RateLimits.reserve_watch({127, 0, 0, 1}, "worker")
  end

  @tag limits: [window_ms: 50, max_buckets: 2, watch_agent: 1]
  test "expired buckets and dead watcher slots are reclaimed without request calls to an owner" do
    assert :ok = RateLimits.check({127, 0, 0, 1}, "worker")
    assert {:error, :unavailable} = RateLimits.check({127, 0, 0, 2}, "another")

    parent = self()

    pid =
      spawn(fn ->
        send(parent, RateLimits.reserve_watch({127, 0, 0, 1}, "worker"))
      end)

    monitor = Process.monitor(pid)
    assert_receive {:ok, _reference}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    # Periodic cleanup is a real runtime contract, with a bound rather than an internal hook.
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert eventually(fn -> RateLimits.check({127, 0, 0, 2}, "another") == :ok end, deadline)
    assert {:ok, _} = RateLimits.reserve_watch({127, 0, 0, 1}, "worker")
  end

  defp eventually(check, deadline) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        eventually(check, deadline)
    end
  end
end

