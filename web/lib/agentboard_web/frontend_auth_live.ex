defmodule AgentboardWeb.FrontendAuthLive do
  @moduledoc "LiveView authentication on mount, reconnect and every data-bearing callback."
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]
  alias Agentboard.FrontendAuth
  alias Agentboard.FrontendAuth.Sessions

  def on_mount(:default, _params, session, socket) do
    if FrontendAuth.enabled?() do
      id = session["frontend_auth_id"]

      case Sessions.validate(id) do
        {:ok, bridge} ->
          if connected?(socket) do
            Phoenix.PubSub.subscribe(Agentboard.PubSub, Sessions.topic(id))
            delay = max(1, bridge.expires_at * 1000 - System.system_time(:millisecond))
            Process.send_after(self(), :frontend_auth_expired, delay)
          end

          socket =
            socket
            |> put_private(:frontend_auth_id, id)
            |> assign(:frontend_identity, bridge.principal)
            |> attach_hook(:frontend_auth_event, :handle_event, &guard_event/3)
            |> attach_hook(:frontend_auth_params, :handle_params, &guard_params/3)
            |> attach_hook(:frontend_auth_info, :handle_info, &guard_info/2)

          {:cont, socket}

        _ ->
          expired(socket)
      end
    else
      {:cont, assign(socket, :frontend_identity, nil)}
    end
  end

  # :x_headers does not include cf-access-* headers. The only socket credential
  # is the opaque bridge supplied through Phoenix's verified session machinery.
  @doc false
  def guard_event(_event, _params, socket), do: authorize(socket)
  @doc false
  def guard_params(_params, _uri, socket), do: authorize(socket)
  @doc false
  def guard_info(message, socket)
      when message in [:frontend_auth_expired, :frontend_auth_revoked] do
    case authorize(socket) do
      {:cont, socket} -> {:halt, socket}
      halted -> halted
    end
  end

  def guard_info(_message, socket), do: authorize(socket)

  defp authorize(socket) do
    case Sessions.validate(socket.private[:frontend_auth_id]) do
      {:ok, _} -> {:cont, socket}
      _ -> expired(socket)
    end
  end

  defp expired(socket), do: {:halt, redirect(socket, to: "/auth/reauthenticate")}
end
