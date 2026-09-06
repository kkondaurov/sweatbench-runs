defmodule GroupStay.Acceptance.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Operations.Record

  @open_occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"

  describe "retrying an applied operation" do
    test "returns the exact original result without changing domain state", %{conn: conn} do
      post_batch(conn, [open_operation("group-81")])

      # Pays exactly the outstanding deposit: a genuine second application
      # would be rejected as payment_exceeds_outstanding.
      first = post_batch(conn, [cash_operation("op-pay", "group-81", 19_500)])
      second = post_batch(conn, [cash_operation("op-pay", "group-81", 19_500)])

      applied = %{
        "operation_id" => "op-pay",
        "status" => "applied",
        "group_id" => "group-81",
        "amount_cents" => 19_500,
        "outstanding_deposit_cents" => 0,
        "revision" => 2
      }

      assert %{"results" => [^applied]} = json_response(first, 200)
      # The retry receives the stored result verbatim, revision included.
      assert %{"results" => [^applied]} = json_response(second, 200)

      assert %{"data" => %{"deposit_paid_cents" => 19_500, "revision" => 2}} =
               get_group!("group-81")
    end

    test "replays across batches regardless of JSON object key order", %{conn: conn} do
      post_batch(conn, [open_operation("group-81")])

      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/v1/partner-batches",
        ~s({"operations":[{"type":"record_cash_payment","group_id":"group-81","occurred_on":"2026-10-04","operation_id":"op-pay","amount_cents":2500}]})
      )
      |> json_response(200)

      reordered =
        ~s({"operations":[{"amount_cents":2500,"operation_id":"op-pay","occurred_on":"2026-10-04","group_id":"group-81","type":"record_cash_payment"}]})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", reordered)

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "amount_cents" => 2_500,
                   "outstanding_deposit_cents" => 17_000,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"deposit_paid_cents" => 2_500}} = get_group!("group-81")
    end

    test "rejects array reordering and value changes as operation_id_conflict", %{conn: conn} do
      post_batch(conn, [open_operation("group-81")])

      rooms_swapped =
        open_operation("group-81")
        |> Map.put("rooms", Enum.reverse(open_operation("group-81")["rooms"]))

      conn = post_batch(conn, [rooms_swapped])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "operation_id_conflict",
                   "operation_id" => "op-1001"
                 }
               ]
             } = json_response(conn, 200)

      # A different value under the same identifier conflicts as well.
      conn = post_batch(conn, [cash_operation("op-pay-x", "group-81", 100)])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      changed_amount =
        cash_operation("op-pay-x", "group-81", 100)
        |> Map.put("amount_cents", 200)

      conn = post_batch(conn, [changed_amount])

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)
      assert %{"data" => %{"deposit_paid_cents" => 100}} = get_group!("group-81")
    end
  end

  describe "retrying a rejected operation" do
    test "returns the original stale-revision details even once revisions move on", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        cash_operation("op-bump", "group-81", 1_000),
        cash_operation("op-stale", "group-81", 999_999) |> Map.put("expected_revision", 1)
      ])

      # Advance the group further before retrying the stale operation.
      post_batch(conn, [cash_operation("op-bump-more", "group-81", 1_000)])

      conn =
        post_batch(conn, [
          cash_operation("op-stale", "group-81", 999_999) |> Map.put("expected_revision", 1)
        ])

      stale = %{
        "operation_id" => "op-stale",
        "status" => "rejected",
        "code" => "stale_revision",
        "group_id" => "group-81",
        "expected_revision" => 1,
        "actual_revision" => 2
      }

      assert %{"results" => [^stale]} = json_response(conn, 200)

      assert %{"data" => ^stale} = get_operation!("op-stale")
    end

    test "returns the original rejection even when the operation would now succeed", %{
      conn: conn
    } do
      # No credit exists yet, so the application is rejected.
      post_batch(conn, [
        open_operation("group-target")
        |> Map.put("operation_id", "op-open-target"),
        apply_credit_operation("op-apply", "group-target", 1_000)
      ])

      # Afterwards the guest earns plenty of credit through a cancellation.
      post_batch(conn, [
        open_operation("group-source") |> Map.put("operation_id", "op-open-source"),
        cash_operation("op-pay-source", "group-source", 8_000),
        cancel_with_refund_method("op-cancel-source", "group-source", "hotel_credit")
      ])

      assert %{"data" => %{"available_cents" => available}} = get_credit!("guest-22")
      assert available > 0

      conn = post_batch(conn, [apply_credit_operation("op-apply", "group-target", 1_000)])

      assert %{"results" => [%{"status" => "rejected", "code" => "insufficient_credit"}]} =
               json_response(conn, 200)

      assert %{"data" => %{"deposit_paid_cents" => 0, "revision" => 1}} =
               get_group!("group-target")
    end

    test "a corrected expected_revision under the same identifier is a conflict", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        cash_operation("op-pay", "group-81", 1_000) |> Map.put("expected_revision", 7)
      ])

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-81", 1_000) |> Map.put("expected_revision", 1)
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               json_response(conn, 200)
    end
  end

  describe "identifier conflicts" do
    test "never replace the original record", %{conn: conn} do
      post_batch(conn, [open_operation("group-81")])

      # First attempt applies normally.
      conn = post_batch(conn, [cash_operation("op-pay", "group-81", 3_000)])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      # A conflicting reuse is rejected and keeps the original untouched.
      conflicting =
        cash_operation("op-pay", "group-81", 3_000)
        |> Map.put("occurred_on", "2026-10-05")

      conn = post_batch(conn, [conflicting])
      assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)

      # The original payload still replays its original result afterwards.
      conn = post_batch(conn, [cash_operation("op-pay", "group-81", 3_000)])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "amount_cents" => 3_000,
                   "outstanding_deposit_cents" => 16_500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "exposes the stored result of an applied operation", %{conn: conn} do
      post_batch(conn, [open_operation("group-81"), cash_operation("op-pay", "group-81", 500)])

      assert %{
               "data" => %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 500,
                 "outstanding_deposit_cents" => 19_000,
                 "revision" => 2
               }
             } = get_operation!("op-pay")
    end

    test "exposes the stored result of a rejected operation", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81") |> Map.put("operation_id", "op-open"),
        cash_operation("op-too-much", "group-81", 999_999)
      ])

      assert %{
               "data" => %{
                 "operation_id" => "op-too-much",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               }
             } = get_operation!("op-too-much")
    end

    test "returns 404 operation_not_found for an unknown identifier", %{conn: conn} do
      conn = get(conn, "/api/v1/operations/op-nowhere")

      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end
  end

  describe "the durable audit record" do
    test "remembers every submitted operation in first-commit order", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81") |> Map.put("operation_id", "op-open"),
        cash_operation("op-exceeds", "group-81", 999_999),
        cash_operation("op-pay", "group-81", 1_000)
      ])

      # Retries add no new records.
      post_batch(conn, [
        cash_operation("op-exceeds", "group-81", 999_999),
        cash_operation("op-pay", "group-81", 1_000)
      ])

      records =
        Repo.all(
          from(r in Record,
            order_by: r.seq,
            select: %{operation_id: r.operation_id, type: r.type, payload: r.payload}
          )
        )

      assert [
               %{operation_id: "op-open"},
               %{operation_id: "op-exceeds"},
               %{operation_id: "op-pay"}
             ] =
               records

      assert Enum.map(records, & &1.type) == [
               "open_group",
               "record_cash_payment",
               "record_cash_payment"
             ]

      # Each record keeps the complete submitted content.
      assert %{
               "arrival_on" => @arrival_on,
               "departure_on" => @departure_on,
               "guest_id" => "guest-22",
               "occurred_on" => @open_occurred_on,
               "property_id" => "ams-canal",
               "rate_plan" => "flexible",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             } = Jason.decode!(hd(records).payload)

      rejected = Enum.find(records, &(&1.operation_id == "op-exceeds"))

      assert Jason.decode!(rejected.payload) == %{
               "amount_cents" => 999_999,
               "group_id" => "group-81",
               "occurred_on" => "2026-10-04",
               "operation_id" => "op-exceeds",
               "type" => "record_cash_payment"
             }
    end

    test "retains the submitted type of an unparseable operation", %{conn: conn} do
      post_batch(conn, [
        %{
          "operation_id" => "op-mystery",
          "type" => "teleport_group",
          "group_id" => "group-81",
          "occurred_on" => @open_occurred_on
        }
      ])

      record = Repo.get_by(Record, operation_id: "op-mystery")

      assert record.type == "teleport_group"
      assert Jason.decode!(record.result)["code"] == "invalid_operation"
    end
  end

  ## Helpers

  defp open_operation(group_id) do
    %{
      "operation_id" => "op-1001",
      "type" => "open_group",
      "occurred_on" => @open_occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => @arrival_on,
      "departure_on" => @departure_on,
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  defp cash_operation(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_with_refund_method(operation_id, group_id, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2026-11-26",
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp apply_credit_operation(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp post_batch(_conn, operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp get_group!(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp get_credit!(guest_id) do
    build_conn()
    |> get("/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
  end

  defp get_operation!(operation_id) do
    build_conn()
    |> get("/api/v1/operations/#{operation_id}")
    |> json_response(200)
  end
end
