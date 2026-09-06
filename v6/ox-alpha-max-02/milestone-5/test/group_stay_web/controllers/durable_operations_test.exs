defmodule GroupStayWeb.Controllers.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  ## Builders

  defp pay(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reschedule(new_arrival, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-81",
        "new_arrival_on" => new_arrival
      },
      overrides
    )
  end

  defp cancel(occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => "group-81"
      },
      overrides
    )
  end

  # The same operation with every object's keys inserted in reverse order.
  # JSON object key order carries no meaning, so this must be equivalent.
  defp reordered(operation) do
    operation
    |> Map.keys()
    |> Enum.reverse()
    |> Map.new(fn key -> {key, Map.fetch!(operation, key)} end)
  end

  describe "replaying applied operations" do
    test "an equivalent retry returns the exact original result", %{conn: conn} do
      original_operation = open_operation(%{"operation_id" => "op-open"})
      [%{"revision" => 1} = original_result] = run_batch(conn, [original_operation])

      assert [%{"status" => "applied", "revision" => 2}] =
               run_batch(conn, [pay("group-81", 5_000)])

      assert hd(run_batch(conn, [reordered(original_operation)])) == original_result

      assert original_result == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 5_000
    end

    test "a retry is answered from the record without consulting current domain state", %{
      conn: conn
    } do
      run_batch(conn, [open_operation()])
      [%{} = paid] = run_batch(conn, [pay("group-81", 5_000)])

      assert [%{"status" => "applied"}] = run_batch(conn, [cancel("2026-11-26")])

      assert hd(run_batch(conn, [pay("group-81", 5_000)])) == paid

      group = fetch_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["revision"] == 3

      assert_ledger(conn, cash_refunded_cents: 5_000)
    end
  end

  describe "remembering rejections" do
    test "a retry receives the original rejection even when it would now succeed", %{
      conn: conn
    } do
      run_batch(conn, [open_operation()])

      [%{} = too_much] = run_batch(conn, [pay("group-81", 999_999)])

      assert too_much == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 0}] =
               run_batch(conn, [pay("group-81", 19_500, %{"operation_id" => "op-pay-full"})])

      assert hd(run_batch(conn, [pay("group-81", 999_999)])) == too_much
      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 19_500
    end

    test "stale-revision details are replayed verbatim and a corrected revision conflicts", %{
      conn: conn
    } do
      run_batch(conn, [open_operation()])

      [%{} = stale] = run_batch(conn, [pay("group-81", 1_000, %{"expected_revision" => 5})])

      assert stale == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 5,
               "actual_revision" => 1
             }

      run_batch(conn, [
        pay("group-81", 100, %{"operation_id" => "op-pay-two"}),
        pay("group-81", 100, %{"operation_id" => "op-pay-three"})
      ])

      assert fetch_group(conn, "group-81")["revision"] == 3

      assert hd(run_batch(conn, [pay("group-81", 1_000, %{"expected_revision" => 5})])) ==
               stale

      assert fetch_group(conn, "group-81")["revision"] == 3

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               run_batch(conn, [pay("group-81", 1_000, %{"expected_revision" => 3})])
    end

    test "identified operations rejected as invalid_operation are remembered too", %{conn: conn} do
      unknown_type = %{
        "operation_id" => "op-weird",
        "type" => "close_group",
        "group_id" => "group-81"
      }

      missing_group = %{
        "operation_id" => "op-missing",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "amount_cents" => 100
      }

      results = run_batch(conn, [unknown_type, missing_group])

      assert results == [
               %{
                 "operation_id" => "op-weird",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "op-missing",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               }
             ]

      retry = run_batch(conn, [unknown_type, missing_group])
      assert retry == results

      assert fetch_operation(conn, "op-weird") == hd(results)
      assert fetch_operation(conn, "op-missing") == hd(tl(results))
    end
  end

  describe "identifier reuse" do
    test "reusing an identifier with a different payload conflicts and preserves the record", %{
      conn: conn
    } do
      run_batch(conn, [open_operation()])
      [%{} = applied] = run_batch(conn, [pay("group-81", 1_000)])

      assert [
               %{
                 "operation_id" => "op-pay",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] = run_batch(conn, [pay("group-81", 2_000)])

      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 1_000
      assert fetch_operation(conn, "op-pay") == applied

      assert hd(run_batch(conn, [pay("group-81", 1_000)])) == applied
    end

    test "object key order is irrelevant to equivalence", %{conn: conn} do
      original = open_operation(%{"operation_id" => "op-order"})
      [%{} = result] = run_batch(conn, [original])

      assert hd(run_batch(conn, [reordered(original)])) == result
    end

    test "array order and values remain significant", %{conn: conn} do
      original = open_operation(%{"operation_id" => "op-rooms"})
      [%{} = _result] = run_batch(conn, [original])

      assert [
               %{
                 "operation_id" => "op-rooms",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] =
               run_batch(conn, [
                 open_operation(%{
                   "operation_id" => "op-rooms",
                   "rooms" => Enum.reverse(original["rooms"])
                 })
               ])
    end

    test "an identical retry inside the same batch replays and the batch continues", %{conn: conn} do
      run_batch(conn, [open_operation()])

      results =
        run_batch(conn, [
          pay("group-81", 1_000, %{"operation_id" => "op-dup"}),
          pay("group-81", 1_000, %{"operation_id" => "op-dup"}),
          pay("group-81", 1_000, %{"operation_id" => "op-next"})
        ])

      assert [
               %{"status" => "applied", "revision" => 2} = first,
               second,
               %{"status" => "applied", "revision" => 3}
             ] = results

      assert second == first

      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 2_000
    end

    test "a conflict inside a batch is reported and the batch continues", %{conn: conn} do
      run_batch(conn, [open_operation(), pay("group-81", 1_000)])

      results =
        run_batch(conn, [
          pay("group-81", 2_000, %{"operation_id" => "op-pay"}),
          pay("group-81", 2_000, %{"operation_id" => "op-fresh"})
        ])

      assert [
               %{
                 "operation_id" => "op-pay",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               },
               %{"status" => "applied", "revision" => 3}
             ] = results

      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 3_000
      assert fetch_operation(conn, "op-fresh") == hd(tl(results))
    end
  end

  describe "gateway retries of whole batches" do
    test "resubmitting a batch returns identical results and applies each operation once", %{
      conn: conn
    } do
      batch = fn ->
        [
          open_operation(%{"operation_id" => "op-1"}),
          open_operation(%{"operation_id" => "op-2"}),
          pay("group-81", 5_000, %{"operation_id" => "op-3"})
        ]
      end

      first = run_batch(conn, batch.())
      assert Enum.map(first, & &1["status"]) == ["applied", "rejected", "applied"]

      second = run_batch(conn, batch.())
      assert second == first

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 5_000
    end
  end

  describe "unexpected server faults" do
    # A nightly rate beyond SQLite's integer range passes domain validation but
    # blows up when the row is bound, like any other unanticipated server fault.
    defp exploding_open(operation_id) do
      open_operation(%{
        "operation_id" => operation_id,
        "group_id" => "g-boom",
        "rooms" => [
          %{"room_id" => "room-boom", "nightly_rate_cents" => 10_000_000_000_000_000_000}
        ]
      })
    end

    test "an exception rolls back the operation and leaves nothing remembered", %{conn: conn} do
      run_batch(conn, [open_operation()])

      assert_raise Exqlite.Error, fn ->
        conn |> submit_batch([exploding_open("op-boom")])
      end

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 1
      assert group["status"] == "active"
      assert fetch_operation(conn, "op-boom") == nil

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "g-after",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ] =
               run_batch(conn, [
                 open_operation(%{
                   "operation_id" => "op-boom",
                   "group_id" => "g-after"
                 })
               ])

      assert %{"status" => "applied", "revision" => 1} = fetch_operation(conn, "op-boom")
    end

    test "operations before the fault stay committed while the faulting one vanishes", %{
      conn: conn
    } do
      assert_raise Exqlite.Error, fn ->
        conn
        |> submit_batch([
          open_operation(%{"operation_id" => "op-first"}),
          pay("group-81", 1_000, %{"operation_id" => "op-second"}),
          exploding_open("op-third")
        ])
      end

      group = fetch_group(conn, "group-81")
      assert group["deposit_paid_cents"] == 1_000
      assert group["revision"] == 2

      assert %{"status" => "applied"} = fetch_operation(conn, "op-first")
      assert %{"status" => "applied"} = fetch_operation(conn, "op-second")
      assert fetch_operation(conn, "op-third") == nil
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result for applied and rejected operations", %{conn: conn} do
      run_batch(conn, [
        open_operation(%{"operation_id" => "op-open"}),
        pay("group-81", 999_999, %{"operation_id" => "op-bad"})
      ])

      assert %{"data" => applied} =
               get(conn, "/api/v1/operations/op-open") |> json_response(200)

      assert applied == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }

      assert %{"data" => rejected} = get(conn, "/api/v1/operations/op-bad") |> json_response(200)

      assert rejected == %{
               "operation_id" => "op-bad",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }
    end

    test "returns the stale-revision rejection exactly as it was returned to the gateway", %{
      conn: conn
    } do
      run_batch(conn, [open_operation()])
      run_batch(conn, [reschedule("2027-01-05", %{"expected_revision" => 4})])

      assert %{"data" => stored} =
               get(conn, "/api/v1/operations/op-move") |> json_response(200)

      assert stored == %{
               "operation_id" => "op-move",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 4,
               "actual_revision" => 1
             }
    end

    test "unknown identifiers return 404 with operation_not_found", %{conn: conn} do
      response = get(conn, "/api/v1/operations/never-submitted")

      assert response.status == 404
      assert json_response(response, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "durable audit trail" do
    test "records retain type, complete submission, and commit order", %{conn: conn} do
      run_batch(conn, [open_operation(%{"operation_id" => "op-1"})])
      run_batch(conn, [open_operation(%{"operation_id" => "op-2"})])
      run_batch(conn, [pay("group-81", 5_000, %{"operation_id" => "op-3"})])
      run_batch(conn, [pay("group-81", 9_999, %{"operation_id" => "op-3"})])

      records = Repo.all(from r in Record, order_by: r.id)

      assert Enum.map(records, & &1.operation_id) == ["op-1", "op-2", "op-3"]
      assert Enum.map(records, & &1.type) == ["open_group", "open_group", "record_cash_payment"]

      submitted_payment = pay("group-81", 5_000, %{"operation_id" => "op-3"})

      assert submitted_payment |> canonical_json() ==
               records |> List.last() |> Map.fetch!(:payload)

      for record <- records do
        {:ok, decoded_result} = Jason.decode(record.result)
        assert decoded_result["operation_id"] == record.operation_id
      end
    end

    test "payloads are stored canonically so key order does not matter", %{conn: conn} do
      original = open_operation(%{"operation_id" => "op-canonical"})
      run_batch(conn, [original])
      run_batch(conn, [reordered(original)])

      assert [%Record{payload: payload}] = Repo.all(Record)
      assert payload == canonical_json(original)
      assert Jason.decode!(payload) == original
    end
  end

  defp canonical_json(operation) do
    members =
      operation
      |> Enum.map(fn {key, value} -> {to_string(key), Jason.encode!(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, encoded} -> Jason.encode!(key) <> ":" <> encoded end)

    "{" <> Enum.join(members, ",") <> "}"
  end

  defp assert_ledger(conn, expectations) do
    assert fetch_ledger(conn) ==
             Map.merge(
               %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               },
               Map.new(expectations, fn {k, v} -> {Atom.to_string(k), v} end)
             )
  end
end
