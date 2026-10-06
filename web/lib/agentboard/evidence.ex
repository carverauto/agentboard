defmodule Agentboard.Evidence do
  use Ash.Domain, backwards_compatible_interface?: false

  resources do
    resource Agentboard.Evidence.Resources.Document
    resource Agentboard.Evidence.Resources.QuotaReport
    resource Agentboard.Evidence.Resources.QuotaObservation
    resource Agentboard.Evidence.Resources.QuotaWindow
    resource Agentboard.Evidence.Resources.QuotaScope
  end
end
