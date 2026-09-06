defmodule GroupStayWeb.RoomAccountingAndPaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Credits.{CreditApplication, CreditLot}
  alias GroupStay.Groups.Group
  alias GroupStay.{Operations, Repo}

  defp open(id, group, rooms, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => group,
        "guest_id" => "guest",
        "property_id" => "ams",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "advance_purchase",
        "rooms" => rooms
      },
      overrides
    )
  end

  defp pay(id, group, amount),
    do: %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group,
      "amount_cents" => amount
    }

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "allocates funding by room and cancels selected rooms in original order", %{conn: conn} do
    rooms = [
      %{"room_id" => "a", "nightly_rate_cents" => 100},
      %{"room_id" => "b", "nightly_rate_cents" => 200},
      %{"room_id" => "c", "nightly_rate_cents" => 300}
    ]

    [_, _] = submit(conn, [open("open", "g", rooms), pay("pay", "g", 350)])
    before = conn |> get("/api/v1/groups/g") |> json_response(200) |> Map.fetch!("data")

    assert Enum.map(before["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) == [
             {"a", 100},
             {"b", 200},
             {"c", 50}
           ]

    [result] =
      submit(conn, [
        %{
          "operation_id" => "partial",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-10-03",
          "group_id" => "g",
          "room_ids" => ["c", "a"]
        }
      ])

    assert result["cancelled_room_ids"] == ["a", "c"]
    assert result["retained_cents"] == 150

    group = conn |> get("/api/v1/groups/g") |> json_response(200) |> Map.fetch!("data")
    assert group["lodging_total_cents"] == 200
    assert group["deposit_due_cents"] == 200
    assert group["cash_paid_cents"] == 200

    assert Enum.map(group["rooms"], &{&1["room_id"], &1["status"]}) == [
             {"a", "cancelled"},
             {"b", "active"},
             {"c", "cancelled"}
           ]
  end

  test "reduces a payment in reverse fill order and reconciles it without changing its stored result",
       %{conn: conn} do
    rooms = [
      %{"room_id" => "a", "nightly_rate_cents" => 100},
      %{"room_id" => "b", "nightly_rate_cents" => 200}
    ]

    [_, original] = submit(conn, [open("open", "g", rooms), pay("pay", "g", 250)])

    [reduced] =
      submit(conn, [
        %{
          "operation_id" => "reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-04",
          "payment_operation_id" => "pay",
          "amount_cents" => 75,
          "expected_revision" => 2
        }
      ])

    assert reduced["outstanding_deposit_cents"] == 125
    assert reduced["revision"] == 3

    group = conn |> get("/api/v1/groups/g") |> json_response(200) |> Map.fetch!("data")
    assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [100, 75]

    statement = conn |> get("/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")

    assert statement == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "g",
             "recorded_cents" => 250,
             "held_cents" => 175,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 75,
             "charged_back_cents" => 0
           }

    assert conn |> get("/api/v1/operations/pay") |> json_response(200) == %{"data" => original}
    assert submit(conn, [pay("pay", "g", 250)]) == [original]
  end

  test "charges back held and settled cash and rejects unsuitable payment records", %{conn: conn} do
    rooms = [%{"room_id" => "a", "nightly_rate_cents" => 100}]

    submit(conn, [
      open("open", "g", rooms),
      pay("pay", "g", 100),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g"
      }
    ])

    [charged] =
      submit(conn, [
        %{
          "operation_id" => "cb",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-04",
          "payment_operation_id" => "pay",
          "expected_revision" => 3
        }
      ])

    assert charged["charged_back_cents"] == 100
    assert charged["outstanding_deposit_cents"] == 0
    assert charged["revision"] == 4

    statement = conn |> get("/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")
    assert statement["refunded_cents"] == 0
    assert statement["charged_back_cents"] == 100
    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 100

    [again, wrong, missing] =
      submit(conn, [
        %{
          "operation_id" => "cb2",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-04",
          "payment_operation_id" => "pay"
        },
        %{
          "operation_id" => "bad",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-04",
          "payment_operation_id" => "open"
        },
        %{
          "operation_id" => "missing",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-04",
          "payment_operation_id" => "nope"
        }
      ])

    assert again["code"] == "payment_not_chargeable"
    assert wrong["code"] == "payment_not_chargeable"
    assert missing["code"] == "operation_not_found"
  end

  test "partial cancellation issues one combined bonus and chargeback creates and clears a shortfall",
       %{conn: conn} do
    tiny = [
      %{"room_id" => "a", "nightly_rate_cents" => 25},
      %{"room_id" => "b", "nightly_rate_cents" => 25}
    ]

    target = [%{"room_id" => "t", "nightly_rate_cents" => 100}]

    submit(conn, [
      open("source-open", "source", tiny, %{"rate_plan" => "flexible"}),
      pay("p1", "source", 5),
      pay("p2", "source", 5),
      %{
        "operation_id" => "convert",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-03",
        "group_id" => "source",
        "room_ids" => ["a", "b"],
        "refund_method" => "hotel_credit"
      },
      open("target-open", "target", target, %{"rate_plan" => "flexible"}),
      %{
        "operation_id" => "use",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "target",
        "amount_cents" => 11
      }
    ])

    credit =
      conn
      |> get("/api/v1/guests/guest/credit?on=2026-10-04")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 0

    [cb] =
      submit(conn, [
        %{
          "operation_id" => "cb",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "p1"
        }
      ])

    assert cb["charged_back_cents"] == 5

    ledger =
      conn |> get("/api/v1/ledger?on=2026-10-05") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 11
    assert ledger["credit_shortfall_cents"] == 6

    target_before =
      conn |> get("/api/v1/groups/target") |> json_response(200) |> Map.fetch!("data")

    [cancelled] =
      submit(conn, [
        %{
          "operation_id" => "target-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-06",
          "group_id" => "target"
        }
      ])

    assert cancelled["revision"] == target_before["revision"] + 1

    ledger =
      conn |> get("/api/v1/ledger?on=2026-10-06") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_shortfall_cents"] == 0
    assert ledger["credit_liability_cents"] == 5
  end

  test "payment endpoint distinguishes missing and non-payment operations", %{conn: conn} do
    rooms = [%{"room_id" => "a", "nightly_rate_cents" => 100}]
    submit(conn, [open("open", "g", rooms)])

    assert conn |> get("/api/v1/payments/absent") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert conn |> get("/api/v1/payments/open") |> json_response(422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end

  test "room cancellation and reduction validation is atomic and revision-aware", %{conn: conn} do
    rooms = [
      %{"room_id" => "a", "nightly_rate_cents" => 100},
      %{"room_id" => "b", "nightly_rate_cents" => 100}
    ]

    submit(conn, [open("open", "g", rooms), pay("pay", "g", 100)])

    [stale, duplicate, too_large] =
      submit(conn, [
        %{
          "operation_id" => "stale",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-10-03",
          "group_id" => "g",
          "room_ids" => ["missing"],
          "expected_revision" => 1
        },
        %{
          "operation_id" => "duplicate",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-10-03",
          "group_id" => "g",
          "room_ids" => ["a", "a"]
        },
        %{
          "operation_id" => "too-large",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-03",
          "payment_operation_id" => "pay",
          "amount_cents" => 101
        }
      ])

    assert stale["code"] == "stale_revision"
    assert duplicate["code"] == "invalid_rooms"
    assert too_large["code"] == "reduction_exceeds_held_cash"
    group = conn |> get("/api/v1/groups/g") |> json_response(200) |> Map.fetch!("data")
    assert {group["revision"], group["cash_paid_cents"]} == {2, 100}

    [exact] =
      submit(conn, [
        %{
          "operation_id" => "exact",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-03",
          "payment_operation_id" => "pay",
          "amount_cents" => 100
        }
      ])

    assert exact["status"] == "applied"

    [empty] =
      submit(conn, [
        %{
          "operation_id" => "empty",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-03",
          "payment_operation_id" => "pay",
          "amount_cents" => 1
        }
      ])

    assert empty["code"] == "payment_not_reducible"
  end

  test "full cancellation after a room cancellation settles only remaining rooms", %{conn: conn} do
    rooms = [
      %{"room_id" => "a", "nightly_rate_cents" => 100},
      %{"room_id" => "b", "nightly_rate_cents" => 100}
    ]

    submit(conn, [open("open", "g", rooms), pay("pay", "g", 200)])

    [first, last] =
      submit(conn, [
        %{
          "operation_id" => "one",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-10-03",
          "group_id" => "g",
          "room_ids" => ["a"]
        },
        %{
          "operation_id" => "all",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "g"
        }
      ])

    assert first["retained_cents"] == 100
    assert last["retained_cents"] == 100
    group = conn |> get("/api/v1/groups/g") |> json_response(200) |> Map.fetch!("data")

    assert {group["status"], group["lodging_total_cents"], group["deposit_due_cents"]} ==
             {"cancelled", 0, 0}
  end

  test "legacy backfill keeps its aggregate block senior to durable funding", %{conn: conn} do
    source_room = [%{"room_id" => "source", "nightly_rate_cents" => 500}]

    target_rooms = [
      %{"room_id" => "a", "nightly_rate_cents" => 100},
      %{"room_id" => "b", "nightly_rate_cents" => 200}
    ]

    submit(conn, [
      open("source-open", "source", source_room, %{"rate_plan" => "flexible"}),
      pay("source-pay", "source", 100),
      %{
        "operation_id" => "lot",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open("target-open", "target", target_rooms),
      %{
        "operation_id" => "durable-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "target",
        "amount_cents" => 30
      },
      pay("durable-cash", "target", 60)
    ])

    target = Repo.get_by!(Group, group_id: "target")
    lot = Repo.one!(from lot in CreditLot, where: lot.source_operation_id == "lot")

    Repo.insert!(
      CreditApplication.changeset(%CreditApplication{}, %{
        group_id: target.id,
        credit_lot_id: lot.id,
        amount_cents: 20,
        status: "active"
      })
    )

    Repo.update!(CreditLot.changeset(lot, %{remaining_cents: lot.remaining_cents - 20}))

    Repo.update!(
      Group.update_changeset(target, %{
        deposit_paid_cents: 150,
        cash_paid_cents: 100,
        credit_paid_cents: 50
      })
    )

    revision = target.revision
    before_ledger = Operations.ledger(~D[2026-10-04])
    Operations.backfill_room_accounting!()

    {:ok, rebuilt} = Operations.get_group("target")
    serialized = Operations.serialize_group(rebuilt)
    assert rebuilt.revision == revision

    assert Enum.map(serialized.rooms, &{&1.cash_paid_cents, &1.credit_paid_cents}) == [
             {50, 50},
             {50, 0}
           ]

    assert Operations.ledger(~D[2026-10-04]) == before_ledger
  end
end
