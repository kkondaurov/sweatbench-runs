defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  describe "transferring held funding" do
    test "moves mixed funding in reverse order and preserves cash and credit provenance", %{
      conn: conn
    } do
      post_batch(conn, [
        open_operation("open-seed", "seed", [
          %{"room_id" => "seed-room", "nightly_rate_cents" => 500}
        ]),
        cash_operation("seed-cash", "seed", 100),
        cancel_operation("seed-credit", "seed", "hotel_credit"),
        open_operation("open-source", "source", standard_rooms()),
        credit_operation("source-credit", "source", 100),
        cash_operation("source-cash", "source", 100),
        open_operation("open-destination", "destination", destination_rooms())
      ])

      ledger_before = get_ledger("2027-01-03")
      transfer = transfer_operation("move", "source", "destination", 150)
      refute Map.has_key?(get_payment("source-cash"), "held_by_group")

      [result] = post_batch(build_conn(), [transfer])

      assert result == %{
               "operation_id" => "move",
               "status" => "applied",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 150,
               "source_outstanding_deposit_cents" => 150,
               "destination_outstanding_deposit_cents" => 0,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      assert get_ledger("2027-01-03") == ledger_before

      assert room_funding("source") == [
               {"source-a", 0, 50},
               {"source-b", 0, 0}
             ]

      assert room_funding("destination") == [
               {"destination-a", 75, 0},
               {"destination-b", 25, 50}
             ]

      assert get_payment("source-cash")["held_by_group"] == [
               %{"group_id" => "destination", "amount_cents" => 100}
             ]

      [replay] = post_batch(build_conn(), [transfer])
      assert replay == result
      assert get_group("source")["revision"] == 4
      assert get_group("destination")["revision"] == 2

      post_batch(build_conn(), [cancel_operation("cancel-destination", "destination", "cash")])

      statement = get_payment("source-cash")
      assert statement["refunded_cents"] == 100
      assert statement["held_by_group"] == []

      credit = get_credit("guest-1", "2027-01-04")
      assert credit["available_cents"] == 60

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "seed-credit",
                 "remaining_cents" => 60,
                 "expires_on" => "2028-01-02"
               }
             ]
    end

    test "validates group lookup and revisions before transfer rules", %{conn: conn} do
      post_batch(conn, [
        open_operation("open-source", "source", standard_rooms()),
        open_operation("open-destination", "destination", destination_standard_rooms()),
        cash_operation("cash", "source", 100)
      ])

      [missing_source, missing_destination, stale_source, stale_destination, same_group] =
        post_batch(build_conn(), [
          transfer_operation("missing-source", "absent", "destination", 1),
          transfer_operation("missing-destination", "source", "absent", 1),
          transfer_operation("stale-source", "source", "destination", 1, %{
            "expected_revision" => 1,
            "destination_expected_revision" => 99
          }),
          transfer_operation("stale-destination", "source", "destination", 1, %{
            "expected_revision" => 2,
            "destination_expected_revision" => 99
          }),
          transfer_operation("same", "source", "source", 1)
        ])

      assert missing_source |> Map.take(["code", "group_id"]) == %{
               "code" => "group_not_found",
               "group_id" => "absent"
             }

      assert missing_destination |> Map.take(["code", "group_id"]) == %{
               "code" => "group_not_found",
               "group_id" => "absent"
             }

      assert stale_source
             |> Map.take(["code", "group_id", "expected_revision", "actual_revision"]) == %{
               "code" => "stale_revision",
               "group_id" => "source",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert stale_destination
             |> Map.take(["code", "group_id", "expected_revision", "actual_revision"]) == %{
               "code" => "stale_revision",
               "group_id" => "destination",
               "expected_revision" => 99,
               "actual_revision" => 1
             }

      assert same_group["code"] == "invalid_transfer"
      assert get_group("source")["revision"] == 2
      assert get_group("destination")["revision"] == 1
    end

    test "rejects inactive parties, invalid amounts, funding excess, and capacity excess", %{
      conn: conn
    } do
      post_batch(conn, [
        open_operation("open-source", "source", standard_rooms()),
        open_operation("open-destination", "destination", destination_standard_rooms()),
        open_operation("open-other", "other", standard_rooms(), %{"guest_id" => "guest-2"}),
        open_operation("open-inactive", "inactive", standard_rooms()),
        cash_operation("source-cash", "source", 100),
        cancel_operation("cancel-inactive", "inactive", "cash")
      ])

      [different_guest, inactive, invalid, funding_excess] =
        post_batch(build_conn(), [
          transfer_operation("different-guest", "source", "other", 1),
          transfer_operation("inactive-party", "inactive", "destination", 1),
          transfer_operation("zero", "source", "destination", 0),
          transfer_operation("too-much", "source", "destination", 101)
        ])

      assert different_guest["code"] == "invalid_transfer"

      assert inactive |> Map.take(["code", "group_id"]) == %{
               "code" => "group_not_active",
               "group_id" => "inactive"
             }

      assert invalid["code"] == "invalid_amount"
      assert funding_excess["code"] == "transfer_exceeds_held_funding"

      post_batch(build_conn(), [cash_operation("fill-destination", "destination", 200)])

      [capacity_excess] =
        post_batch(build_conn(), [transfer_operation("no-capacity", "source", "destination", 1)])

      assert capacity_excess["code"] == "transfer_exceeds_outstanding"
    end
  end

  describe "corrections after transfers" do
    test "reduces transferred cash across groups in reverse allocation order", %{conn: conn} do
      post_batch(conn, [
        open_operation("open-source", "source", standard_rooms()),
        open_operation("open-destination", "destination", destination_standard_rooms()),
        cash_operation("cash", "source", 200),
        transfer_operation("move", "source", "destination", 150)
      ])

      assert get_payment("cash")["held_by_group"] == [
               %{"group_id" => "destination", "amount_cents" => 150},
               %{"group_id" => "source", "amount_cents" => 50}
             ]

      [reduction] = post_batch(build_conn(), [reduce_operation("reduce", "cash", 170)])

      assert reduction
             |> Map.take(["group_id", "amount_cents", "outstanding_deposit_cents", "revision"]) ==
               %{
                 "group_id" => "source",
                 "amount_cents" => 170,
                 "outstanding_deposit_cents" => 170,
                 "revision" => 4
               }

      assert get_group("destination")["revision"] == 3
      assert room_funding("destination") == [{"destination-a", 0, 0}, {"destination-b", 0, 0}]

      statement = get_payment("cash")
      assert statement["held_cents"] == 30
      assert statement["reduced_cents"] == 170

      assert statement["held_by_group"] == [
               %{"group_id" => "source", "amount_cents" => 30}
             ]
    end

    test "chargeback revises every group holding or settling transferred cash", %{conn: conn} do
      post_batch(conn, [
        open_operation("open-source", "source", standard_rooms()),
        open_operation("open-destination", "destination", destination_standard_rooms()),
        cash_operation("cash", "source", 200),
        transfer_operation("move", "source", "destination", 100),
        cancel_rooms_operation("cancel-destination-a", "destination", ["destination-a"])
      ])

      [chargeback] = post_batch(build_conn(), [chargeback_operation("chargeback", "cash")])

      assert chargeback |> Map.take(["group_id", "charged_back_cents", "revision"]) == %{
               "group_id" => "source",
               "charged_back_cents" => 200,
               "revision" => 4
             }

      assert get_group("destination")["revision"] == 4
      assert get_payment("cash")["charged_back_cents"] == 200
      assert get_payment("cash")["held_by_group"] == []

      ledger = get_ledger("2027-01-05")
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 200
    end
  end

  defp standard_rooms do
    [
      %{"room_id" => "source-a", "nightly_rate_cents" => 500},
      %{"room_id" => "source-b", "nightly_rate_cents" => 500}
    ]
  end

  defp destination_rooms do
    [
      %{"room_id" => "destination-a", "nightly_rate_cents" => 375},
      %{"room_id" => "destination-b", "nightly_rate_cents" => 375}
    ]
  end

  defp destination_standard_rooms do
    [
      %{"room_id" => "destination-a", "nightly_rate_cents" => 500},
      %{"room_id" => "destination-b", "nightly_rate_cents" => 500}
    ]
  end

  defp open_operation(operation_id, group_id, rooms, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-12-01",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "hotel-1",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "flexible",
        "rooms" => rooms
      },
      overrides
    )
  end

  defp cash_operation(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit_operation(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-03",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_operation(operation_id, group_id, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp cancel_rooms_operation(operation_id, group_id, room_ids) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2027-01-04",
      "group_id" => group_id,
      "room_ids" => room_ids
    }
  end

  defp transfer_operation(operation_id, source, destination, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "transfer_deposit",
        "occurred_on" => "2027-01-03",
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reduce_operation(operation_id, payment_operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-04",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
    }
  end

  defp chargeback_operation(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-05",
      "payment_operation_id" => payment_operation_id
    }
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_group(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp room_funding(group_id) do
    group_id
    |> get_group()
    |> Map.fetch!("rooms")
    |> Enum.map(&{&1["room_id"], &1["cash_paid_cents"], &1["credit_paid_cents"]})
  end

  defp get_payment(operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_credit(guest_id, on) do
    build_conn()
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_ledger(on) do
    build_conn()
    |> get("/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
