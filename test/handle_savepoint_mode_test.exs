defmodule EctoLibSql.HandleSavepointModeTest do
  @moduledoc """
  Tests for the savepoint mode support added to handle_begin/2, handle_commit/2,
  and handle_rollback/2 in EctoLibSql.

  The Ecto SQL Sandbox uses `mode: :savepoint` to nest transactions without
  issuing a real BEGIN (which SQLite does not support inside an existing
  transaction). These tests verify that:

  - handle_begin creates a SAVEPOINT when a transaction is already active
  - handle_commit releases the savepoint, leaving the outer transaction open
  - handle_rollback rolls back to the savepoint, leaving the outer transaction open
  - The ETS tracking table is kept consistent across all paths
  - Data isolation is correct for both commit and rollback of savepoints
  """

  use ExUnit.Case, async: true

  alias EctoLibSql.Native
  alias EctoLibSql.State
  alias EctoLibSql.Query

  @savepoint_table :ecto_libsql_savepoints

  # Execute SQL via the public handle_execute interface
  defp exec_sql(state, sql, args \\ []) do
    EctoLibSql.handle_execute(%Query{statement: sql}, args, [], state)
  end

  # Begin a real (outer) transaction and return the resulting state
  defp begin_outer(state) do
    {:ok, :begin, trx_state} = EctoLibSql.handle_begin([], state)
    trx_state
  end

  setup do
    db_file = "z_ecto_libsql_test-handle_sp_#{:erlang.unique_integer([:positive])}.db"
    conn_id = Native.connect([database: db_file], :local)
    state = %State{conn_id: conn_id, mode: :local, sync: :disable_sync}

    {:ok, _, _, state} =
      exec_sql(state, "CREATE TABLE items (id INTEGER PRIMARY KEY, val TEXT)")

    on_exit(fn ->
      Native.close(state.conn_id, :conn_id)
      EctoLibSql.TestHelpers.cleanup_db_files(db_file)
    end)

    {:ok, state: state}
  end

  # ---------------------------------------------------------------------------
  # handle_begin
  # ---------------------------------------------------------------------------

  describe "handle_begin with mode: :savepoint" do
    test "falls through to normal BEGIN when no transaction is active", %{state: state} do
      assert is_nil(state.trx_id)

      assert {:ok, :begin, trx_state} = EctoLibSql.handle_begin([mode: :savepoint], state)
      assert is_binary(trx_state.trx_id)

      EctoLibSql.handle_rollback([], trx_state)
    end

    test "creates a SAVEPOINT when a transaction is already active", %{state: state} do
      trx_state = begin_outer(state)

      assert {:ok, :savepoint, ^trx_state} =
               EctoLibSql.handle_begin([mode: :savepoint], trx_state)

      # ETS should now track a savepoint name for this transaction
      assert [{_trx_id, sp_name}] = :ets.lookup(@savepoint_table, trx_state.trx_id)
      assert String.starts_with?(sp_name, "ecto_sp_")

      EctoLibSql.handle_rollback([], trx_state)
    end

    test "returned state is unchanged (same trx_id) when creating a savepoint", %{state: state} do
      trx_state = begin_outer(state)

      {:ok, :savepoint, returned_state} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)

      assert returned_state == trx_state

      EctoLibSql.handle_rollback([], trx_state)
    end

    test "consecutive calls generate distinct savepoint names", %{state: state} do
      trx_state = begin_outer(state)

      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)
      [{_, sp1}] = :ets.lookup(@savepoint_table, trx_state.trx_id)

      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)
      [{_, sp2}] = :ets.lookup(@savepoint_table, trx_state.trx_id)

      refute sp1 == sp2

      EctoLibSql.handle_rollback([], trx_state)
    end

    test "without mode option performs a normal BEGIN", %{state: state} do
      assert {:ok, :begin, trx_state} = EctoLibSql.handle_begin([], state)
      assert is_binary(trx_state.trx_id)

      EctoLibSql.handle_rollback([], trx_state)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_commit
  # ---------------------------------------------------------------------------

  describe "handle_commit" do
    test "releases the savepoint and keeps the outer transaction open when one is tracked",
         %{state: state} do
      trx_state = begin_outer(state)
      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)

      assert {:ok, %EctoLibSql.Result{}, committed_state} =
               EctoLibSql.handle_commit([], trx_state)

      # Outer transaction is still active
      assert committed_state.trx_id == trx_state.trx_id

      # ETS entry has been removed
      assert :ets.lookup(@savepoint_table, trx_state.trx_id) == []

      EctoLibSql.handle_commit([], committed_state)
    end

    test "commits the outer transaction when no savepoint is tracked", %{state: state} do
      trx_state = begin_outer(state)

      assert {:ok, %EctoLibSql.Result{}, clean_state} = EctoLibSql.handle_commit([], trx_state)
      assert is_nil(clean_state.trx_id)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_rollback
  # ---------------------------------------------------------------------------

  describe "handle_rollback" do
    test "rolls back to the savepoint and keeps the outer transaction open when one is tracked",
         %{state: state} do
      trx_state = begin_outer(state)
      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)

      assert {:ok, %EctoLibSql.Result{}, rolled_back_state} =
               EctoLibSql.handle_rollback([], trx_state)

      # Outer transaction still active
      assert rolled_back_state.trx_id == trx_state.trx_id

      # ETS entry has been removed
      assert :ets.lookup(@savepoint_table, trx_state.trx_id) == []

      EctoLibSql.handle_rollback([], trx_state)
    end

    test "rolls back the outer transaction when no savepoint is tracked", %{state: state} do
      trx_state = begin_outer(state)

      assert {:ok, %EctoLibSql.Result{}, clean_state} =
               EctoLibSql.handle_rollback([], trx_state)

      assert is_nil(clean_state.trx_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Data isolation
  # ---------------------------------------------------------------------------

  describe "data isolation" do
    test "savepoint commit preserves both inner and outer changes", %{state: state} do
      trx_state = begin_outer(state)
      {:ok, _, _, trx_state} = exec_sql(trx_state, "INSERT INTO items VALUES (1, 'outer')")

      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)
      {:ok, _, _, trx_state} = exec_sql(trx_state, "INSERT INTO items VALUES (2, 'inner')")

      {:ok, _, trx_state} = EctoLibSql.handle_commit([], trx_state)
      # Savepoint released — commit the outer transaction
      EctoLibSql.handle_commit([], trx_state)

      {:ok, _, result, _} = exec_sql(state, "SELECT val FROM items ORDER BY id")
      assert Enum.map(result.rows, &hd/1) == ["outer", "inner"]
    end

    test "savepoint rollback discards inner changes while preserving outer changes", %{
      state: state
    } do
      trx_state = begin_outer(state)
      {:ok, _, _, trx_state} = exec_sql(trx_state, "INSERT INTO items VALUES (1, 'outer')")

      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)
      {:ok, _, _, trx_state} = exec_sql(trx_state, "INSERT INTO items VALUES (2, 'discarded')")

      {:ok, _, trx_state} = EctoLibSql.handle_rollback([], trx_state)
      EctoLibSql.handle_commit([], trx_state)

      {:ok, _, result, _} = exec_sql(state, "SELECT val FROM items ORDER BY id")
      assert Enum.map(result.rows, &hd/1) == ["outer"]
    end

    test "rolling back the outer transaction discards all changes, including released savepoints",
         %{state: state} do
      trx_state = begin_outer(state)
      {:ok, _, _, trx_state} = exec_sql(trx_state, "INSERT INTO items VALUES (1, 'a')")

      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)
      {:ok, _, _, trx_state} = exec_sql(trx_state, "INSERT INTO items VALUES (2, 'b')")

      # Commit the savepoint (release it into the outer transaction)
      {:ok, _, trx_state} = EctoLibSql.handle_commit([], trx_state)

      # Roll back the entire outer transaction
      EctoLibSql.handle_rollback([], trx_state)

      {:ok, _, result, _} = exec_sql(state, "SELECT * FROM items")
      assert result.rows == []
    end
  end

  # ---------------------------------------------------------------------------
  # ETS tracking table
  # ---------------------------------------------------------------------------

  describe "ETS tracking table" do
    test "entry is removed after a savepoint commit", %{state: state} do
      trx_state = begin_outer(state)
      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)

      assert [{_, _}] = :ets.lookup(@savepoint_table, trx_state.trx_id)

      EctoLibSql.handle_commit([], trx_state)

      assert [] = :ets.lookup(@savepoint_table, trx_state.trx_id)

      EctoLibSql.handle_rollback([], trx_state)
    end

    test "entry is removed after a savepoint rollback", %{state: state} do
      trx_state = begin_outer(state)
      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx_state)

      assert [{_, _}] = :ets.lookup(@savepoint_table, trx_state.trx_id)

      EctoLibSql.handle_rollback([], trx_state)

      assert [] = :ets.lookup(@savepoint_table, trx_state.trx_id)

      EctoLibSql.handle_rollback([], trx_state)
    end

    test "entries for distinct transactions do not interfere with each other", %{state: state} do
      db_file2 = "z_ecto_libsql_test-handle_sp2_#{:erlang.unique_integer([:positive])}.db"
      conn_id2 = Native.connect([database: db_file2], :local)
      state2 = %State{conn_id: conn_id2, mode: :local, sync: :disable_sync}
      {:ok, _, _, state2} = exec_sql(state2, "CREATE TABLE items (id INTEGER PRIMARY KEY, val TEXT)")

      on_exit(fn ->
        Native.close(conn_id2, :conn_id)
        EctoLibSql.TestHelpers.cleanup_db_files(db_file2)
      end)

      trx1 = begin_outer(state)
      trx2 = begin_outer(state2)

      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx1)
      {:ok, :savepoint, _} = EctoLibSql.handle_begin([mode: :savepoint], trx2)

      [{_, sp1}] = :ets.lookup(@savepoint_table, trx1.trx_id)
      [{_, sp2}] = :ets.lookup(@savepoint_table, trx2.trx_id)

      assert String.starts_with?(sp1, "ecto_sp_")
      assert String.starts_with?(sp2, "ecto_sp_")
      refute trx1.trx_id == trx2.trx_id

      # Committing the savepoint for trx1 must not affect trx2's entry
      EctoLibSql.handle_commit([mode: :savepoint], trx1)
      assert :ets.lookup(@savepoint_table, trx1.trx_id) == []
      assert [{_, ^sp2}] = :ets.lookup(@savepoint_table, trx2.trx_id)

      # Clean up
      EctoLibSql.handle_rollback([mode: :savepoint], trx2)
      EctoLibSql.handle_rollback([], trx1)
      EctoLibSql.handle_rollback([], trx2)
    end
  end
end
