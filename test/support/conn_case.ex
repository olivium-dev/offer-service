defmodule OfferServiceWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import OfferService.Fixtures

      alias OfferServiceWeb.Router.Helpers, as: Routes

      @endpoint OfferServiceWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(OfferService.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
