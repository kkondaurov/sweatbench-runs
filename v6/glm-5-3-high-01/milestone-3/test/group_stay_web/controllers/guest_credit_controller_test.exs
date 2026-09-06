defmodule GroupStayWeb.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  @moduledoc false

  describe "GET /api/v1/guests/:guest_id/credit" do
    test "reports no credit for a guest without lots" do
      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert json_response(conn, 200) == %{
               "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
             }
    end

    test "returns available lots ordered by expiry then source operation" do
      issue_credit!(
        group_id: "group-a",
        amount: 3000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-a"
      )

      issue_credit!(
        group_id: "group-b",
        amount: 2000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-b"
      )

      issue_credit!(
        group_id: "group-c",
        amount: 4000,
        cancel_on: ~D[2026-12-26],
        cancel_op: "cancel-c"
      )

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert json_response(conn, 200)["data"]["lots"] == [
               %{
                 "source_operation_id" => "cancel-a",
                 "remaining_cents" => 3300,
                 "expires_on" => "2027-11-26"
               },
               %{
                 "source_operation_id" => "cancel-b",
                 "remaining_cents" => 2200,
                 "expires_on" => "2027-11-26"
               },
               %{
                 "source_operation_id" => "cancel-c",
                 "remaining_cents" => 4400,
                 "expires_on" => "2027-12-26"
               }
             ]

      assert json_response(conn, 200)["data"]["available_cents"] == 9900
    end

    test "omits lots that have expired or been exhausted" do
      issue_credit!(
        group_id: "group-a",
        amount: 3000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-a"
      )

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-11-26")
      assert [%{"remaining_cents" => 3300}] = json_response(conn, 200)["data"]["lots"]

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-11-27")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "rejects an unparseable on date" do
      conn = get(build_conn(), "/api/v1/guests/guest-22/credit?on=not-a-date")

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end
  end

  describe "apply_hotel_credit" do
    test "redeems unexpired credit into the active deposit" do
      issue_credit!(
        group_id: "group-1",
        amount: 5000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-1"
      )

      apply_operations!(build_conn(), [
        open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"})
      ])

      conn =
        submit(build_conn(), [
          apply_credit_operation(%{
            "group_id" => "group-2",
            "amount_cents" => 5500,
            "occurred_on" => "2026-10-10"
          })
        ])

      assert [%{"status" => "applied"} = result] = json_response(conn, 200)["results"]

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "applied",
               "group_id" => "group-2",
               "amount_cents" => 5500,
               "outstanding_deposit_cents" => 3500,
               "revision" => 2
             }

      conn = get(build_conn(), "/api/v1/groups/group-2")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 5500
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 5500
      assert data["outstanding_deposit_cents"] == 3500

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 0
      assert json_response(conn, 200)["data"]["lots"] == []

      conn = get(build_conn(), "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 5500
    end

    test "credit can be applied on the lot's expiry date but not after it" do
      issue_credit!(
        group_id: "group-1",
        amount: 2000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-1"
      )

      apply_operations!(build_conn(), [
        open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"})
      ])

      conn =
        submit(build_conn(), [
          apply_credit_operation(%{
            "group_id" => "group-2",
            "amount_cents" => 2200,
            "occurred_on" => "2027-11-27",
            "operation_id" => "op-credit-late"
          })
        ])

      assert [%{"code" => "insufficient_credit"}] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          apply_credit_operation(%{
            "group_id" => "group-2",
            "amount_cents" => 2200,
            "occurred_on" => "2027-11-26",
            "operation_id" => "op-credit-last-day"
          })
        ])

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 6800}] =
               json_response(conn, 200)["results"]
    end

    test "consumes lots by earliest expiry then source operation" do
      issue_credit!(
        group_id: "group-a",
        amount: 3000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-a"
      )

      issue_credit!(
        group_id: "group-b",
        amount: 2000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-b"
      )

      issue_credit!(
        group_id: "group-c",
        amount: 4000,
        cancel_on: ~D[2026-12-26],
        cancel_op: "cancel-c"
      )

      apply_operations!(build_conn(), [
        open_group_operation(%{"group_id" => "group-d", "operation_id" => "op-open-d"}),
        apply_credit_operation(%{
          "group_id" => "group-d",
          "amount_cents" => 3800,
          "occurred_on" => "2026-10-10"
        })
      ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert json_response(conn, 200)["data"]["lots"] == [
               %{
                 "source_operation_id" => "cancel-b",
                 "remaining_cents" => 1700,
                 "expires_on" => "2027-11-26"
               },
               %{
                 "source_operation_id" => "cancel-c",
                 "remaining_cents" => 4400,
                 "expires_on" => "2027-12-26"
               }
             ]
    end

    test "rejects a request the guest cannot cover" do
      issue_credit!(
        group_id: "group-1",
        amount: 5000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-1"
      )

      apply_operations!(build_conn(), [
        open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"})
      ])

      conn =
        submit(build_conn(), [
          apply_credit_operation(%{"group_id" => "group-2", "amount_cents" => 5501})
        ])

      assert [%{"code" => "insufficient_credit"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/groups/group-2")
      assert json_response(conn, 200)["data"]["revision"] == 1

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 5500
    end

    test "uses the existing payment validation errors" do
      issue_credit!(
        group_id: "group-1",
        amount: 5000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-1"
      )

      apply_operations!(build_conn(), [
        open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"})
      ])

      for {amount, index} <- Enum.with_index([0, -100, "2000", 200.5, nil]) do
        conn =
          submit(build_conn(), [
            apply_credit_operation(%{
              "group_id" => "group-2",
              "amount_cents" => amount,
              "operation_id" => "op-credit-amount-#{index}"
            })
          ])

        assert [%{"code" => "invalid_amount"}] = json_response(conn, 200)["results"]
      end

      conn =
        submit(build_conn(), [
          apply_credit_operation(%{
            "group_id" => "group-2",
            "amount_cents" => 9001,
            "operation_id" => "op-credit-too-much"
          })
        ])

      assert [%{"code" => "payment_exceeds_outstanding"}] = json_response(conn, 200)["results"]
    end

    test "rejects applications for missing or inactive groups" do
      conn = submit(build_conn(), [apply_credit_operation(%{"group_id" => "nope"})])
      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]

      apply_operations!(build_conn(), [
        open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"}),
        cancel_operation(%{"group_id" => "group-2", "occurred_on" => "2026-11-26"})
      ])

      conn =
        submit(build_conn(), [
          apply_credit_operation(%{"group_id" => "group-2", "operation_id" => "op-credit-2"})
        ])

      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end

    test "checks the revision before the credit domain rules" do
      issue_credit!(
        group_id: "group-1",
        amount: 5000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-1"
      )

      apply_operations!(build_conn(), [
        open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"})
      ])

      conn =
        submit(build_conn(), [
          apply_credit_operation(%{
            "group_id" => "group-2",
            "amount_cents" => 999_999,
            "expected_revision" => 99,
            "operation_id" => "op-credit-stale"
          })
        ])

      assert [
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-2",
                 "expected_revision" => 99,
                 "actual_revision" => 1
               }
             ] = json_response(conn, 200)["results"]

      conn =
        submit(build_conn(), [
          apply_credit_operation(%{
            "group_id" => "group-2",
            "amount_cents" => 5500,
            "expected_revision" => 1,
            "operation_id" => "op-credit-current"
          })
        ])

      assert [%{"status" => "applied", "revision" => 2}] = json_response(conn, 200)["results"]
    end
  end

  describe "settling a group funded by credit" do
    test "a refundable cash cancellation restores credit to its original lot and expiry" do
      issue_credit!(
        group_id: "group-1",
        amount: 5000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-1"
      )

      apply_operations!(build_conn(), [
        open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"}),
        apply_credit_operation(%{
          "group_id" => "group-2",
          "amount_cents" => 5500,
          "occurred_on" => "2026-10-10"
        }),
        cancel_operation(%{
          "group_id" => "group-2",
          "operation_id" => "cancel-2",
          "occurred_on" => "2026-11-26"
        })
      ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-1",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }
    end

    test "a refundable hotel-credit cancellation converts only the cash portion" do
      issue_credit!(
        group_id: "group-1",
        amount: 5000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-1"
      )

      assert [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 2200,
                 "revision" => 4
               }
             ] =
               apply_operations!(build_conn(), [
                 open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"}),
                 payment_operation(%{
                   "group_id" => "group-2",
                   "operation_id" => "op-pay-2",
                   "occurred_on" => "2026-10-10",
                   "amount_cents" => 2000
                 }),
                 apply_credit_operation(%{
                   "group_id" => "group-2",
                   "amount_cents" => 5500,
                   "occurred_on" => "2026-10-11"
                 }),
                 cancel_operation(%{
                   "group_id" => "group-2",
                   "operation_id" => "cancel-2",
                   "occurred_on" => "2026-11-26",
                   "refund_method" => "hotel_credit"
                 })
               ])
               |> Enum.drop(3)

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")

      assert json_response(conn, 200)["data"]["lots"] == [
               %{
                 "source_operation_id" => "cancel-1",
                 "remaining_cents" => 5500,
                 "expires_on" => "2027-11-26"
               },
               %{
                 "source_operation_id" => "cancel-2",
                 "remaining_cents" => 2200,
                 "expires_on" => "2027-11-26"
               }
             ]

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 7000,
               "credit_liability_cents" => 7700
             }
    end

    test "restored credit whose lot already expired does not become available again" do
      issue_credit!(
        group_id: "group-1",
        amount: 5000,
        cancel_on: ~D[2026-02-01],
        cancel_op: "cancel-1"
      )

      apply_operations!(build_conn(), [
        open_group_operation(%{
          "group_id" => "group-2",
          "operation_id" => "op-open-2",
          "occurred_on" => "2026-12-01",
          "arrival_on" => "2028-01-15",
          "departure_on" => "2028-01-18"
        }),
        payment_operation(%{
          "group_id" => "group-2",
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-12-02",
          "amount_cents" => 1000
        }),
        apply_credit_operation(%{
          "group_id" => "group-2",
          "amount_cents" => 5500,
          "occurred_on" => "2027-01-10"
        }),
        cancel_operation(%{
          "group_id" => "group-2",
          "operation_id" => "cancel-2",
          "occurred_on" => "2027-12-10"
        })
      ])

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-12-10")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      conn = get(build_conn(), "/api/v1/ledger?on=2027-12-10")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 1000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 0
             }
    end

    test "a non-refundable cancellation retains cash and consumes applied credit" do
      issue_credit!(
        group_id: "group-1",
        amount: 5000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-1"
      )

      assert [
               %{"refunded_cents" => 0, "retained_cents" => 1000, "credit_issued_cents" => 0}
             ] =
               apply_operations!(build_conn(), [
                 open_group_operation(%{"group_id" => "group-2", "operation_id" => "op-open-2"}),
                 payment_operation(%{
                   "group_id" => "group-2",
                   "operation_id" => "op-pay-2",
                   "occurred_on" => "2026-10-10",
                   "amount_cents" => 1000
                 }),
                 apply_credit_operation(%{
                   "group_id" => "group-2",
                   "amount_cents" => 5500,
                   "occurred_on" => "2026-10-11"
                 }),
                 cancel_operation(%{
                   "group_id" => "group-2",
                   "operation_id" => "cancel-2",
                   "occurred_on" => "2026-12-01"
                 })
               ])
               |> Enum.drop(3)

      conn = get(build_conn(), "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 1000,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 0
             }
    end
  end

  describe "GET /api/v1/ledger expiry reporting" do
    test "the on parameter reports expiry as of that date" do
      issue_credit!(
        group_id: "group-1",
        amount: 5000,
        cancel_on: ~D[2026-11-26],
        cancel_op: "cancel-1"
      )

      conn = get(build_conn(), "/api/v1/ledger?on=2027-11-26")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 5500

      conn = get(build_conn(), "/api/v1/ledger?on=2027-11-27")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 0
    end

    test "rejects an unparseable on date" do
      conn = get(build_conn(), "/api/v1/ledger?on=2026-13-01")

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end
  end

  defp issue_credit!(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    amount = Keyword.fetch!(opts, :amount)
    cancel_on = Keyword.fetch!(opts, :cancel_on)
    cancel_op = Keyword.fetch!(opts, :cancel_op)

    apply_operations!(build_conn(), [
      open_group_operation(%{
        "group_id" => group_id,
        "operation_id" => "op-open-#{group_id}",
        "occurred_on" => Date.to_iso8601(Date.add(cancel_on, -60)),
        "arrival_on" => Date.to_iso8601(Date.add(cancel_on, 20)),
        "departure_on" => Date.to_iso8601(Date.add(cancel_on, 23))
      }),
      payment_operation(%{
        "group_id" => group_id,
        "operation_id" => "op-pay-#{group_id}",
        "occurred_on" => Date.to_iso8601(Date.add(cancel_on, -59)),
        "amount_cents" => amount
      }),
      cancel_operation(%{
        "group_id" => group_id,
        "operation_id" => cancel_op,
        "occurred_on" => Date.to_iso8601(cancel_on),
        "refund_method" => "hotel_credit"
      })
    ])
  end
end
