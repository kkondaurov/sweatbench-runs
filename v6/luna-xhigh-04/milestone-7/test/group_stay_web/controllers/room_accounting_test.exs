defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  alias Ecto.Changeset
  alias GroupStay.{CashPayment, CreditAllocation, CreditLot, Group, Ledger, OperationRecord, Repo}

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: operation_id,
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2026-12-20",
        departure_on: "2026-12-23",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 15000},
          %{room_id: "room-b", nightly_rate_cents: 17500}
        ]
      },
      overrides
    )
  end

  test "allocates cash in room order and settles only selected rooms", %{conn: conn} do
    assert post_batch(conn, [open_operation("open")]) |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "pay-a",
               type: "record_cash_payment",
               occurred_on: "2026-10-04",
               group_id: "group-81",
               amount_cents: 12000
             },
             %{
               operation_id: "pay-b",
               type: "record_cash_payment",
               occurred_on: "2026-10-05",
               group_id: "group-81",
               amount_cents: 2000
             }
           ])
           |> json_response(200)

    result =
      post_batch(conn, [
        %{
          operation_id: "cancel-b",
          type: "cancel_rooms",
          occurred_on: "2026-11-01",
          group_id: "group-81",
          room_ids: ["room-b"]
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result == %{
             "operation_id" => "cancel-b",
             "status" => "applied",
             "group_id" => "group-81",
             "cancelled_room_ids" => ["room-b"],
             "refunded_cents" => 5000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 4
           }

    group =
      get(build_conn(), "/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert group["deposit_due_cents"] == 9000
    assert group["deposit_paid_cents"] == 9000
    assert group["cash_paid_cents"] == 9000
    assert group["outstanding_deposit_cents"] == 0

    assert group["rooms"] == [
             %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15000,
               "status" => "active",
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 9000,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 17500,
               "status" => "cancelled",
               "deposit_due_cents" => 10500,
               "cash_paid_cents" => 5000,
               "credit_paid_cents" => 0
             }
           ]

    assert get(build_conn(), "/api/v1/payments/pay-a")
           |> json_response(200)
           |> get_in(["data"]) == %{
             "payment_operation_id" => "pay-a",
             "original_group_id" => "group-81",
             "recorded_cents" => 12000,
             "held_cents" => 9000,
             "refunded_cents" => 3000,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    assert get(build_conn(), "/api/v1/payments/pay-b")
           |> json_response(200)
           |> get_in(["data", "refunded_cents"]) == 2000
  end

  test "reduces held cash from the last room allocation first", %{conn: conn} do
    assert post_batch(conn, [open_operation("open")]) |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "pay",
               type: "record_cash_payment",
               occurred_on: "2026-10-04",
               group_id: "group-81",
               amount_cents: 10000
             }
           ])
           |> json_response(200)

    first =
      post_batch(conn, [
        %{
          operation_id: "reduce-1",
          type: "reduce_cash_payment",
          occurred_on: "2026-10-06",
          payment_operation_id: "pay",
          amount_cents: 500
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert first["status"] == "applied"
    assert first["outstanding_deposit_cents"] == 10000

    second =
      post_batch(conn, [
        %{
          operation_id: "reduce-2",
          type: "reduce_cash_payment",
          occurred_on: "2026-10-07",
          payment_operation_id: "pay",
          amount_cents: 500
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert second["status"] == "applied"
    assert second["outstanding_deposit_cents"] == 10500

    assert get(build_conn(), "/api/v1/payments/pay")
           |> json_response(200)
           |> get_in(["data"]) == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "group-81",
             "recorded_cents" => 10000,
             "held_cents" => 9000,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 1000,
             "charged_back_cents" => 0
           }

    assert get(build_conn(), "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "cash_reduced_cents"]) == 1000
  end

  test "chargebacks revoke a payment's credit entitlement and report shortfall", %{conn: conn} do
    source = open_operation("open-source", %{group_id: "source"})

    use_group =
      open_operation("open-use", %{
        group_id: "use",
        arrival_on: "2027-04-20",
        departure_on: "2027-04-22"
      })

    assert post_batch(conn, [source]) |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "pay-a",
               type: "record_cash_payment",
               occurred_on: "2026-10-04",
               group_id: "source",
               amount_cents: 1000
             },
             %{
               operation_id: "pay-b",
               type: "record_cash_payment",
               occurred_on: "2026-10-05",
               group_id: "source",
               amount_cents: 1000
             },
             %{
               operation_id: "convert",
               type: "cancel_group",
               occurred_on: "2026-10-06",
               group_id: "source",
               refund_method: "hotel_credit"
             }
           ])
           |> json_response(200)

    assert post_batch(conn, [use_group]) |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "use-credit",
               type: "apply_hotel_credit",
               occurred_on: "2026-10-07",
               group_id: "use",
               amount_cents: 1500
             }
           ])
           |> json_response(200)

    chargeback =
      post_batch(conn, [
        %{
          operation_id: "chargeback-a",
          type: "charge_back_payment",
          occurred_on: "2026-10-08",
          payment_operation_id: "pay-a"
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert chargeback["status"] == "applied"
    assert chargeback["charged_back_cents"] == 1000

    ledger = get(build_conn(), "/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_charged_back_cents"] == 1000
    assert ledger["cash_converted_to_credit_cents"] == 1000
    assert ledger["credit_shortfall_cents"] == 400
    assert ledger["credit_liability_cents"] == 1500

    assert post_batch(conn, [
             %{
               operation_id: "cancel-use",
               type: "cancel_group",
               occurred_on: "2027-01-01",
               group_id: "use"
             }
           ])
           |> json_response(200)

    ledger = get(build_conn(), "/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["credit_shortfall_cents"] == 0
    assert ledger["credit_liability_cents"] == 1100
  end

  test "chargeback moves mixed current dispositions and is itself idempotent", %{conn: conn} do
    assert post_batch(conn, [open_operation("open")]) |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "pay",
               type: "record_cash_payment",
               occurred_on: "2026-10-04",
               group_id: "group-81",
               amount_cents: 10000
             },
             %{
               operation_id: "cancel-a",
               type: "cancel_rooms",
               occurred_on: "2026-11-01",
               group_id: "group-81",
               room_ids: ["room-a"]
             }
           ])
           |> json_response(200)

    chargeback = %{
      operation_id: "chargeback",
      type: "charge_back_payment",
      occurred_on: "2026-11-02",
      payment_operation_id: "pay"
    }

    first =
      post_batch(conn, [chargeback])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert first["charged_back_cents"] == 10000
    assert first["revision"] == 4

    assert post_batch(conn, [chargeback])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == first

    assert get(build_conn(), "/api/v1/payments/pay")
           |> json_response(200)
           |> get_in(["data"]) == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "group-81",
             "recorded_cents" => 10000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 10000
           }

    assert get(build_conn(), "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data"])
           |> Map.take(["revision", "deposit_paid_cents", "outstanding_deposit_cents"]) ==
             %{"revision" => 4, "deposit_paid_cents" => 0, "outstanding_deposit_cents" => 10500}
  end

  test "brings legacy aggregate funding into room allocations in durable commit order", %{
    conn: conn
  } do
    assert post_batch(conn, [open_operation("open", %{group_id: "legacy"})]) |> json_response(200)

    group = Repo.get!(Group, "legacy")

    group
    |> Changeset.change(
      deposit_paid_cents: 10500,
      cash_paid_cents: 9500,
      credit_paid_cents: 1000
    )
    |> Repo.update!()

    Repo.get!(Ledger, 1)
    |> Changeset.change(cash_held_cents: 9500)
    |> Repo.update!()

    lot =
      Repo.insert!(%CreditLot{
        guest_id: "guest-22",
        source_operation_id: "legacy-credit-lot",
        remaining_cents: 0,
        expires_on: ~D[2027-12-31],
        unrecovered_clawback_cents: 0
      })

    Repo.insert!(%CreditAllocation{
      group_id: "legacy",
      credit_lot_id: lot.id,
      amount_cents: 1000
    })

    Repo.insert!(%OperationRecord{
      operation_id: "old-credit",
      type: "apply_hotel_credit",
      payload: %{operation_id: "old-credit", type: "apply_hotel_credit"},
      result: %{
        "operation_id" => "old-credit",
        "status" => "applied",
        "group_id" => "legacy",
        "amount_cents" => 1000
      }
    })

    Repo.insert!(%OperationRecord{
      operation_id: "old-cash",
      type: "record_cash_payment",
      payload: %{operation_id: "old-cash", type: "record_cash_payment"},
      result: %{
        "operation_id" => "old-cash",
        "status" => "applied",
        "group_id" => "legacy",
        "amount_cents" => 500
      }
    })

    group = get(build_conn(), "/api/v1/groups/legacy") |> json_response(200) |> Map.fetch!("data")

    assert Enum.map(
             group["rooms"],
             &Map.take(&1, ["room_id", "cash_paid_cents", "credit_paid_cents"])
           ) == [
             %{"room_id" => "room-a", "cash_paid_cents" => 9000, "credit_paid_cents" => 0},
             %{"room_id" => "room-b", "cash_paid_cents" => 500, "credit_paid_cents" => 1000}
           ]

    assert Repo.get_by!(CashPayment, payment_operation_id: "old-cash").held_cents == 500
    assert Repo.get_by!(CreditAllocation, funding_operation_id: "old-credit").room_id == "room-b"
    assert Repo.get!(Ledger, 1).cash_held_cents == 9500
  end
end
