defmodule GroupStayWeb.DurableOperationsTest do
  @moduledoc """
  Acceptance tests for the durable-operations release: partner operations are
  durably idempotent by `operation_id`, rejections are remembered, conflicts
  are detected, and remembered results are readable through the operations
  endpoint.
  """

  use GroupStayWeb.ConnCase, async: false

  @batch_url "/api/v1/partner-batches"

  defp post_batch(conn, operations) do
    post(conn, @batch_url, %{"operations" => operations})
  end

  defp post_raw_batch(raw) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(@batch_url, raw)
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp open_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-open"),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-pay"),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9_500
      },
      overrides
    )
  end

  defp cancel_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-cancel"),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-credit"),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp apply_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end

  defp reject_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "rejected", "expected rejected, got: #{inspect(result)}"
    result
  end

  defp open_group!(conn, overrides \\ %{}) do
    apply_operation!(conn, open_group_operation(overrides))
  end

  defp fetch_group(conn, group_id) do
    conn = get(conn, "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp fetch_operation(conn, operation_id) do
    conn = get(conn, "/api/v1/operations/#{operation_id}")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp ledger(conn) do
    conn = get(conn, "/api/v1/ledger")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  describe "retrying an applied operation" do
    test "returns the exact original result without changing domain state", %{conn: conn} do
      open_group!(conn)

      payment = payment_operation()
      original = apply_operation!(conn, payment)

      conn
      |> post_batch([payment])
      |> json_response(200)
      |> then(fn %{"results" => [result]} ->
        assert result == original
        assert result["revision"] == 2
        assert result["outstanding_deposit_cents"] == 10_000
      end)

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 9_500

      assert ledger(conn)["cash_held_cents"] == 9_500
    end

    test "returns the original result even after later operations changed state", %{conn: conn} do
      open_group!(conn)

      payment = payment_operation()
      original = apply_operation!(conn, payment)

      # Later operations move the group on; the retry must not observe them.
      apply_operation!(
        conn,
        payment_operation(%{"amount_cents" => 10_000})
      )

      apply_operation!(conn, cancel_operation())

      conn
      |> post_batch([payment])
      |> json_response(200)
      |> then(fn %{"results" => [result]} ->
        assert result == original
        assert result["revision"] == 2
        assert result["outstanding_deposit_cents"] == 10_000
      end)

      group = fetch_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["revision"] == 4
      # Room-accounting release: the group's paid total describes active
      # rooms only, and a cancelled group has none.
      assert group["deposit_paid_cents"] == 0

      assert ledger(conn)["cash_refunded_cents"] == 19_500
    end

    test "a duplicate operation in the same batch is replayed", %{conn: conn} do
      open_group!(conn)

      payment = payment_operation()

      conn
      |> post_batch([payment, payment])
      |> json_response(200)
      |> then(fn %{"results" => [first, second]} ->
        assert first["status"] == "applied"
        assert first["revision"] == 2
        assert second == first
      end)

      assert fetch_group(conn, "group-81")["revision"] == 2
    end
  end

  describe "payload equivalence" do
    test "object key order is irrelevant", %{conn: conn} do
      open_group!(conn)

      payment_id = unique_id("op-pay")

      first =
        post_raw_batch(
          ~s({"operations":[{"type":"record_cash_payment","operation_id":"#{payment_id}","occurred_on":"2026-10-04","group_id":"group-81","amount_cents":9500}]})
        )
        |> json_response(200)

      second =
        post_raw_batch(
          ~s({"operations":[{"amount_cents":9500,"group_id":"group-81","occurred_on":"2026-10-04","operation_id":"#{payment_id}","type":"record_cash_payment"}]})
        )
        |> json_response(200)

      assert second == first

      assert fetch_group(conn, "group-81")["revision"] == 2
    end

    test "nested object key order is irrelevant", %{conn: conn} do
      open_id = unique_id("op-open")

      first =
        post_raw_batch(
          ~s({"operations":[{"operation_id":"#{open_id}","type":"open_group","occurred_on":"2026-10-03","group_id":"group-ko","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"}]}]})
        )
        |> json_response(200)

      second =
        post_raw_batch(
          ~s({"operations":[{"rooms":[{"room_id":"room-a","nightly_rate_cents":15000}],"rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-ko","occurred_on":"2026-10-03","type":"open_group","operation_id":"#{open_id}"}]})
        )
        |> json_response(200)

      assert second == first

      assert fetch_group(conn, "group-ko")["revision"] == 1
    end

    test "array order is significant", %{conn: conn} do
      operation =
        open_group_operation(%{
          "operation_id" => "op-rooms-order",
          "group_id" => "group-rooms"
        })

      apply_operation!(conn, operation)

      reordered =
        open_group_operation(%{
          "operation_id" => "op-rooms-order",
          "group_id" => "group-rooms",
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
        })

      result = reject_operation!(conn, reordered)

      assert result["code"] == "operation_id_conflict"
    end

    test "changed values are a conflict", %{conn: conn} do
      open_group!(conn)

      apply_operation!(conn, payment_operation(%{"operation_id" => "op-pay-x"}))

      result =
        reject_operation!(
          conn,
          payment_operation(%{"operation_id" => "op-pay-x", "amount_cents" => 1_000})
        )

      assert result["code"] == "operation_id_conflict"

      # The conflict rejection carries the usual rejection shape.
      assert result["status"] == "rejected"
      assert result["operation_id"] == "op-pay-x"
    end
  end

  describe "conflicts" do
    test "do not replace the original record", %{conn: conn} do
      open_group!(conn)

      payment = payment_operation(%{"operation_id" => "op-pay-keep"})
      original = apply_operation!(conn, payment)

      reject_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-keep", "amount_cents" => 5_000})
      )

      conn
      |> post_batch([payment])
      |> json_response(200)
      |> then(fn %{"results" => [result]} -> assert result == original end)

      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 9_500
    end

    test "continue the batch in order", %{conn: conn} do
      open_group!(conn)

      conn =
        post_batch(conn, [
          payment_operation(%{"operation_id" => "op-pay-a"}),
          payment_operation(%{"operation_id" => "op-pay-a", "amount_cents" => 1_000}),
          payment_operation(%{"operation_id" => "op-pay-b", "amount_cents" => 10_000})
        ])

      assert %{"results" => [first, second, third]} = json_response(conn, 200)

      assert first["status"] == "applied"
      assert first["revision"] == 2

      assert second == %{
               "operation_id" => "op-pay-a",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert third["status"] == "applied"
      assert third["revision"] == 3

      assert fetch_group(conn, "group-81")["revision"] == 3
      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 19_500
    end
  end

  describe "remembered rejections" do
    test "return the original rejection even when it would now be valid", %{conn: conn} do
      missing =
        payment_operation(%{"operation_id" => "op-pay-missing", "group_id" => "group-later"})

      result = reject_operation!(conn, missing)
      assert result["code"] == "group_not_found"

      open_group!(conn, %{"group_id" => "group-later"})

      conn
      |> post_batch([missing])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} ->
        assert retried == result
        assert retried["code"] == "group_not_found"
      end)

      # The replay neither read the new group nor changed it.
      group = fetch_group(conn, "group-later")
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
    end

    test "remember an insufficient_credit rejection even after credit is issued", %{conn: conn} do
      open_group!(conn)

      credit_op = apply_credit_operation(%{"operation_id" => "op-credit-none"})
      result = reject_operation!(conn, credit_op)
      assert result["code"] == "insufficient_credit"

      # Issue credit to the guest from another refundable group.
      open_group!(conn, %{
        "group_id" => "group-src",
        "arrival_on" => "2027-06-10",
        "departure_on" => "2027-06-13"
      })

      apply_operation!(
        conn,
        payment_operation(%{"group_id" => "group-src", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        cancel_operation(%{
          "group_id" => "group-src",
          "refund_method" => "hotel_credit"
        })
      )

      conn
      |> post_batch([credit_op])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} ->
        assert retried == result
        assert retried["code"] == "insufficient_credit"
      end)

      assert fetch_group(conn, "group-81")["credit_paid_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 5_500
    end

    test "remember invalid_operation rejections for unknown types", %{conn: conn} do
      operation = %{
        "operation_id" => "op-noop",
        "type" => "noop",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      }

      result = reject_operation!(conn, operation)
      assert result["code"] == "invalid_operation"

      conn
      |> post_batch([operation])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} -> assert retried == result end)
    end

    test "leave domain state unchanged but are readable", %{conn: conn} do
      open_group!(conn)

      result =
        reject_operation!(
          conn,
          payment_operation(%{"operation_id" => "op-pay-too-much", "amount_cents" => 20_000})
        )

      assert result["code"] == "payment_exceeds_outstanding"

      assert fetch_operation(conn, "op-pay-too-much") == result

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
    end

    test "do not remember operations without a usable operation_id", %{conn: conn} do
      open_group!(conn)

      for overrides <- [%{"operation_id" => nil}, %{"operation_id" => ""}] do
        result = reject_operation!(conn, payment_operation(overrides))
        assert result["code"] == "invalid_operation"
      end

      conn = get(conn, "/api/v1/operations/")
      assert conn.status == 404
    end
  end

  describe "revisions in stored results" do
    test "an exact retry returns the stale rejection verbatim", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation())

      stale = payment_operation(%{"operation_id" => "op-pay-stale", "expected_revision" => 1})
      result = reject_operation!(conn, stale)

      assert result == %{
               "operation_id" => "op-pay-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      conn
      |> post_batch([stale])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} -> assert retried == result end)

      assert fetch_group(conn, "group-81")["revision"] == 2
    end

    test "a corrected expected_revision under the same identifier is a conflict", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation())

      reject_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-stale", "expected_revision" => 1})
      )

      result =
        reject_operation!(
          conn,
          payment_operation(%{"operation_id" => "op-pay-stale", "expected_revision" => 2})
        )

      assert result["code"] == "operation_id_conflict"
      assert fetch_group(conn, "group-81")["revision"] == 2
    end
  end

  describe "reading operations" do
    test "returns the stored result of an applied operation", %{conn: conn} do
      open_group!(conn)

      payment = payment_operation(%{"operation_id" => "op-pay-read"})
      result = apply_operation!(conn, payment)

      conn = get(conn, "/api/v1/operations/op-pay-read")

      assert json_response(conn, 200) == %{"data" => result}
    end

    test "returns the stored result of a rejected operation", %{conn: conn} do
      reject_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-read-rej",
          "group_id" => "group-missing"
        })
      )

      conn = get(conn, "/api/v1/operations/op-pay-read-rej")

      assert %{"data" => data} = json_response(conn, 200)

      assert data == %{
               "operation_id" => "op-pay-read-rej",
               "status" => "rejected",
               "code" => "group_not_found"
             }
    end

    test "exposes only the stored result", %{conn: conn} do
      open_group_operation(%{"operation_id" => "op-open-audit"})
      |> then(&apply_operation!(conn, &1))

      conn = get(conn, "/api/v1/operations/op-open-audit")

      assert %{"data" => data} = json_response(conn, 200)

      assert Map.keys(data) == [
               "deposit_due_cents",
               "group_id",
               "operation_id",
               "revision",
               "status"
             ]
    end

    test "returns 404 operation_not_found for an unknown identifier", %{conn: conn} do
      conn = get(conn, "/api/v1/operations/op-never-seen")

      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end
  end

  describe "unexpected exceptions" do
    @tag :unexpected_fault
    test "roll back the operation, are not remembered, and abort the batch", %{conn: conn} do
      open_group!(conn)

      payment = payment_operation(%{"operation_id" => "op-pay-before-fault"})
      apply_operation!(conn, payment)

      # A nightly rate beyond SQLite's integer range raises an unexpected
      # fault while applying the operation.
      assert_raise Exqlite.Error, fn ->
        post_batch(conn, [
          %{
            "operation_id" => "op-fault",
            "type" => "open_group",
            "occurred_on" => "2026-10-03",
            "group_id" => "group-fault",
            "guest_id" => "guest-22",
            "property_id" => "ams-canal",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-13",
            "rate_plan" => "flexible",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 9_000_000_000_000_000_000_000}
            ]
          },
          payment_operation(%{"operation_id" => "op-pay-after-fault"})
        ])
      end

      # The faulting operation left no domain state behind...
      conn = get(build_conn(), "/api/v1/groups/group-fault")
      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)

      # ...and was not remembered as an idempotent result.
      conn = get(build_conn(), "/api/v1/operations/op-fault")
      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)

      # The batch aborted: the operation after the fault never ran...
      conn = get(build_conn(), "/api/v1/operations/op-pay-after-fault")
      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)

      # ...while the operation committed before the fault is durable.
      assert fetch_operation(build_conn(), "op-pay-before-fault")["status"] == "applied"

      group = fetch_group(build_conn(), "group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 9_500

      # The gateway may retry the batch: the remembered operation replays and
      # the retried fault can be attempted again (and still fails cleanly).
      conn =
        post_batch(build_conn(), [
          payment_operation(%{"operation_id" => "op-pay-after-fault"})
        ])

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "applied"
      assert result["revision"] == 3
    end
  end
end
