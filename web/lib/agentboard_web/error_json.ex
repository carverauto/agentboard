defmodule AgentboardWeb.ErrorJSON do
  def render(template, _assigns) do
    %{
      error: %{
        code: "request_failed",
        message: Phoenix.Controller.status_message_from_template(template)
      }
    }
  end
end

