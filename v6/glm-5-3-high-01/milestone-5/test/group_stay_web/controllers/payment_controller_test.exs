defmodule GroupStayWeb.PaymentControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  @moduledoc false

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports every disposition of an applied cash payment" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "operation_id" => "op-open",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
          ]
        }),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 10000}),
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 2000}),
        reduce_cash_operation(%{
          "operation_id" => "op-reduce",
          "payment_operation_id" => "op-pay-2",
          "amount_cents" => 500
        }),
        cancel_rooms_operation(%{
          "operation_id" => "op-cancel-rooms",
          "room_ids" => ["room-b"]
        })
      ])

      conn = get(build_conn(), "/api/v1/payments/op-pay-1")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "op-pay-1",
               "original_group_id" => "group-1",
               "recorded_cents" => 10_000,
               "held_cents" => 9000,
               "refunded_cents" => 1000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      conn = get(build_conn(), "/api/v1/payments/op-pay-2")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "op-pay-2",
               "original_group_id" => "group-1",
               "recorded_cents" => 2000,
               "held_cents" => 0,
               "refunded_cents" => 1500,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 500,
               "charged_back_cents" => 0
             }
    end

    test "exposes exactly the documented fields, including when zero" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 3000})
      ])

      conn = get(build_conn(), "/api/v1/payments/op-pay")
      data = json_response(conn, 200)["data"]

      assert Map.keys(data) |> Enum.sort() ==
               Enum.sort([
                 "payment_operation_id",
                 "original_group_id",
                 "recorded_cents",
                 "held_cents",
                 "refunded_cents",
                 "retained_cents",
                 "converted_to_credit_cents",
                 "reduced_cents",
                 "charged_back_cents"
               ])

      assert data["recorded_cents"] ==
               data["held_cents"] +
                 data["refunded_cents"] +
                 data["retained_cents"] +
                 data["converted_to_credit_cents"] +
                 data["reduced_cents"] +
                 data["charged_back_cents"]
    end

    test "the statement agrees with the group, room, and ledger views" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 3000}),
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 2000})
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      group = json_response(conn, 200)["data"]

      conn = get(build_conn(), "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      assert group["cash_paid_cents"] == 5000
      assert group["deposit_paid_cents"] == 5000
      assert group["cash_paid_cents"] == ledger["cash_held_cents"]

      # Recorded cash equals held plus refunded, retained, converted, reduced,
      # and charged-back cash.
      assert 5000 ==
               ledger["cash_held_cents"] +
                 ledger["cash_refunded_cents"] +
                 ledger["cash_retained_cents"] +
                 ledger["cash_converted_to_credit_cents"] +
                 ledger["cash_reduced_cents"] +
                 ledger["cash_charged_back_cents"]
    end

    test "returns operation_not_found when no durable record exists" do
      conn = get(build_conn(), "/api/v1/payments/op-never")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns payment_not_reconcilable for records that are not applied cash payments" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 3000}),
        cancel_operation(%{"operation_id" => "op-cancel"})
      ])

      # A payment that exceeded the outstanding deposit leaves a rejected
      # durable record behind.
      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-pay-rejected",
            "group_id" => "group-1",
            "amount_cents" => 999_999
          })
        ])

      assert [%{"status" => "rejected"}] = json_response(conn, 200)["results"]

      for operation_id <- ["op-open", "op-cancel", "op-pay-rejected"] do
        conn = get(build_conn(), "/api/v1/payments/#{operation_id}")

        assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}},
               "expected payment_not_reconcilable for #{operation_id}"
      end
    end

    test "reading a statement never changes state" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-open"}),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 3000})
      ])

      conn = get(build_conn(), "/api/v1/payments/op-pay")
      assert json_response(conn, 200)["data"]["held_cents"] == 3000

      conn = get(build_conn(), "/api/v1/payments/op-pay")
      assert json_response(conn, 200)["data"]["held_cents"] == 3000

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 2
      assert data["cash_paid_cents"] == 3000

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 3000
    end
  end
end
