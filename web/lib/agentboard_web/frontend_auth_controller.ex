defmodule AgentboardWeb.FrontendAuthController do
  use Phoenix.Controller, formats: [:html]
  alias AgentboardWeb.Plugs.FrontendAuth

  def reauthenticate(conn, _params) do
    # The browser pipeline has already verified a fresh HTTP assertion.
    redirect(conn, to: "/")
  end

  def logout(conn, _params) do
    conn = conn |> FrontendAuth.revoke_session() |> configure_session(renew: true)

    if Agentboard.FrontendAuth.enabled?() do
      # Cloudflare handles its own cookie logout on this same-origin endpoint.
      # Local revocation also blocks copied bridge cookies and existing sockets.
      redirect(conn, to: "/cdn-cgi/access/logout")
    else
      redirect(conn, to: "/")
    end
  end
end
