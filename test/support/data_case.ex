defmodule OfferService.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      alias OfferService.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import OfferService.DataCase
      import OfferService.Fixtures
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(OfferService.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
