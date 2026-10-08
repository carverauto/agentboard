defmodule Agentboard.Vault do
  @moduledoc """
  Cloak vault for server-side secrets at rest (phase 2 elastic bot
  tokens). The key comes from a file-backed Secret ref configured in
  `runtime.exs`, never the repo. Tokens are re-issuable, so a key
  rotation is recovered by re-provisioning, not by decrypting old rows.
  """
  use Cloak.Vault, otp_app: :agentboard
end
