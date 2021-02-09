# This file draws heavily from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE

defmodule Realtime.Adapters.Postgres.EpgsqlImplementation do
  @behaviour Realtime.Adapters.Postgres.AdapterBehaviour
  require Logger

  def init(config) do
    with {:ok, select_epgsql_pid} <-
           Postgrex.start_link(
             hostname: "localhost",
             username: "postgres",
             password: "postgres",
             database: "postgres"
           ),
         {:ok, replication_epgsql_pid} <-
           start_replication(config, select_epgsql_pid) do
      {:ok, replication_epgsql_pid}
    else
      reason ->
        {:error, reason}
    end
  end

  defp start_replication(config, select_epgsql_pid) do
    {xlog, offset} = Keyword.get(config, :wal_position, {"0", "0"})

    publication_names =
      Keyword.get(config, :publications)
      |> Enum.map(fn pub -> ~s("#{pub}") end)
      |> Enum.join(",")

    with {:ok, replication_epgsql_pid} <-
           Keyword.get(config, :epgsql, %{})
           |> Map.put(:replication, "database")
           |> :epgsql.connect(),
         {:ok, slot_name} <-
           create_replication_slot(
             replication_epgsql_pid,
             select_epgsql_pid,
             Keyword.get(config, :slot, :temporary)
           ),
         :ok <-
           :epgsql.start_replication(
             replication_epgsql_pid,
             slot_name,
             self(),
             [],
             '#{xlog}/#{offset}',
             'proto_version \'1\', publication_names \'#{publication_names}\''
           ) do
      {:ok, replication_epgsql_pid}
    else
      reason -> {:error, reason}
    end
  end

  @impl true
  def acknowledge_lsn(epgsql, {_xlog, _offset} = lsn_tup) do
    decimal_lsn = lsn_tuple_to_decimal(lsn_tup)

    :epgsql.standby_status_update(epgsql, decimal_lsn, decimal_lsn)
  end

  defp lsn_tuple_to_decimal({xlog, offset}) do
    <<decimal_lsn::integer-64>> = <<xlog::integer-32, offset::integer-32>>
    decimal_lsn
  end

  defp create_replication_slot(replication_epgsql_pid, select_epgsql_pid, slot) do
    {slot_name, start_replication_command} =
      case slot do
        name when is_binary(name) ->
          # Simple query for replication mode so no prepared statements are supported
          escaped_name = String.downcase(String.replace(name, "'", "\\'"))

          query =
            "SELECT COUNT(*) >= 1 FROM pg_replication_slots WHERE slot_name = '#{escaped_name}'"

          %Postgrex.Result{rows: [[existing_slot]]} =
            Postgrex.query!(select_epgsql_pid, query, [])

          case existing_slot do
            true ->
              # no-op
              {name, "SELECT 1"}

            false ->
              {name, "CREATE_REPLICATION_SLOT #{escaped_name} LOGICAL pgoutput NOEXPORT_SNAPSHOT"}
          end

        :temporary ->
          slot_name = self_as_slot_name()

          {slot_name,
           "CREATE_REPLICATION_SLOT #{slot_name} TEMPORARY LOGICAL pgoutput NOEXPORT_SNAPSHOT"}
      end

    if start_replication_command == "SELECT 1" do
      Postgrex.query!(select_epgsql_pid, start_replication_command, [])
      # Process.exit(select_epgsql_pid, :kill)
      {:ok, slot_name}
    else
      case :epgsql.squery(replication_epgsql_pid, start_replication_command) do
        {:ok, _, _} ->
          # Process.exit(select_epgsql_pid, :kill)
          {:ok, slot_name}

        {:error, epgsql_error} ->
          {:error, epgsql_error}
      end
    end
  end

  # TODO: Replace with better slot name generator
  defp self_as_slot_name() do
    "#PID<" <> pid = inspect(self())

    pid_number =
      String.replace(pid, ".", "_")
      |> String.slice(0..-2)

    "pid" <> pid_number
  end
end
