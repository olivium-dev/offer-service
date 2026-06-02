defmodule OfferService.Clients.ChatClientContractTest do
  @moduledoc """
  GUARD: OFFER-R1-CHAT-CONTRACT.

  Spec-example contract test for the chat-service integration that backs the
  offer-accept saga. Rather than mocking the `ChatClient` behaviour (which the
  rest of the suite already does via Mox), this test exercises the *real*
  `OfferService.Clients.ChatClient.HTTP` implementation against a throwaway
  local HTTP server, so it catches drift in:

    (a) the endpoint path/verb actually called — `POST /internal/threads`;
    (b) the serialised request body shape —
        `{request_id, offer_id, participants: [%{user_id, role}]}`;
    (c) the success response contract — a 2xx with a `thread_id` key is parsed
        into `{:ok, %{thread_id: ...}}`;
    (d) the failure contract — 404 / 405 / unexpected status / unexpected body
        all map to `{:error, :chat_service_unavailable}` (never a crash and
        never a false `:ok`).

  This is additive-only: it adds a new test module and touches no production
  code. It temporarily overrides the `:chat_service_url` application env to
  point at the local server, restoring it on exit.
  """

  use ExUnit.Case, async: false

  alias OfferService.Clients.ChatClient.HTTP

  @path "/internal/threads"

  setup do
    # Stand up a minimal local HTTP server whose behaviour is driven per-test
    # by a function stored in the test process via :persistent_term-free state.
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> {200, %{"thread_id" => "thread-default"}} end)

    plug_opts = [agent: agent, test_pid: test_pid]

    {:ok, _} =
      Plug.Cowboy.http(__MODULE__.Router, plug_opts,
        port: 0,
        ref: make_ref_name()
      )

    {ref, port} = server_info()

    prev_url = Application.get_env(:offer_service, :chat_service_url)
    Application.put_env(:offer_service, :chat_service_url, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      :ok = Plug.Cowboy.shutdown(ref)

      if is_nil(prev_url) do
        Application.delete_env(:offer_service, :chat_service_url)
      else
        Application.put_env(:offer_service, :chat_service_url, prev_url)
      end

      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    {:ok, agent: agent}
  end

  # We use a single named ref per test process so shutdown is deterministic.
  defp make_ref_name do
    name = :"chat_contract_#{System.unique_integer([:positive])}"
    Process.put(:chat_contract_ref, name)
    name
  end

  defp server_info do
    ref = Process.get(:chat_contract_ref)
    port = :ranch.get_port(ref)
    {ref, port}
  end

  defp params do
    %{
      request_id: Ecto.UUID.generate(),
      offer_id: Ecto.UUID.generate(),
      client_id: Ecto.UUID.generate(),
      jeeber_id: Ecto.UUID.generate()
    }
  end

  describe "POST /internal/threads — endpoint + request contract" do
    test "calls POST /internal/threads with the documented body shape", %{agent: agent} do
      Agent.update(agent, fn _ -> {201, %{"thread_id" => "thread-xyz"}} end)

      p = params()
      assert {:ok, %{thread_id: "thread-xyz"}} = HTTP.create_thread(p)

      assert_receive {:chat_request, method, path, body}, 2_000

      assert method == "POST"
      assert path == @path

      # (b) request body deserialises into the documented shape.
      assert body["request_id"] == p.request_id
      assert body["offer_id"] == p.offer_id
      assert is_list(body["participants"])
      assert length(body["participants"]) == 2

      roles = body["participants"] |> Enum.map(& &1["role"]) |> Enum.sort()
      assert roles == ["client", "jeeber"]

      user_ids = body["participants"] |> Enum.map(& &1["user_id"]) |> MapSet.new()
      assert MapSet.member?(user_ids, p.client_id)
      assert MapSet.member?(user_ids, p.jeeber_id)
    end
  end

  describe "POST /internal/threads — response contract" do
    test "parses thread_id from a 200 response", %{agent: agent} do
      Agent.update(agent, fn _ -> {200, %{"thread_id" => "t-200"}} end)
      assert {:ok, %{thread_id: "t-200"}} = HTTP.create_thread(params())
    end

    test "thread_id is a string in the success envelope", %{agent: agent} do
      Agent.update(agent, fn _ -> {200, %{"thread_id" => "t-typed"}} end)
      assert {:ok, %{thread_id: thread_id}} = HTTP.create_thread(params())
      assert is_binary(thread_id)
    end

    test "404 from the chat service is treated as unavailable, not a crash", %{agent: agent} do
      Agent.update(agent, fn _ -> {404, %{"error" => "not_found"}} end)
      assert {:error, :chat_service_unavailable} = HTTP.create_thread(params())
    end

    test "405 from the chat service is treated as unavailable", %{agent: agent} do
      Agent.update(agent, fn _ -> {405, %{"error" => "method_not_allowed"}} end)
      assert {:error, :chat_service_unavailable} = HTTP.create_thread(params())
    end

    test "a 2xx without thread_id is rejected (not a false success)", %{agent: agent} do
      Agent.update(agent, fn _ -> {200, %{"unexpected" => true}} end)
      assert {:error, :chat_service_unavailable} = HTTP.create_thread(params())
    end

    test "a 500 from the chat service is treated as unavailable", %{agent: agent} do
      Agent.update(agent, fn _ -> {500, %{"error" => "boom"}} end)
      assert {:error, :chat_service_unavailable} = HTTP.create_thread(params())
    end
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      test_pid = Keyword.fetch!(opts, :test_pid)

      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)

      send(test_pid, {:chat_request, conn.method, conn.request_path, body})

      {status, payload} = Agent.get(agent, & &1)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end
  end
end
