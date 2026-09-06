defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{CreditLot, Repo}

  defp open_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp apply_result(conn, operation),
    do: post_batch(conn, [operation]) |> json_response(200) |> Map.fetch!("results") |> hd()

  defp credit_lot(attrs) do
    Repo.insert!(
      %CreditLot{
        guest_id: "guest-1",
        source_operation_id: "source-1",
        remaining_cents: 100,
        expires_on: ~D[2027-06-01],
        cash_converted_cents: 0,
        issued_on: ~D[2027-01-01]
      }
      |> struct(attrs)
    )
  end

  test "fixes policy at booking and recomputes the deadline after rescheduling", %{conn: conn} do
    post_batch(conn, [
      open_operation(%{
        "group_id" => "legacy",
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-03"
      }),
      open_operation(%{
        "operation_id" => "open-2",
        "group_id" => "new-policy",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-03"
      })
    ])

    assert %{
             "policy_version" => "flex-14",
             "refundable_until" => "2027-02-15"
           } = json_response(get(conn, "/api/v1/groups/legacy"), 200)["data"]

    assert %{
             "policy_version" => "flex-30",
             "refundable_until" => "2027-01-30"
           } = json_response(get(conn, "/api/v1/groups/new-policy"), 200)["data"]

    result =
      apply_result(conn, %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "legacy",
        "new_arrival_on" => "2027-04-01"
      })

    assert result["policy_version"] == "flex-14"
    assert result["refundable_until"] == "2027-03-18"
  end

  test "issues hotel credit with a rounded bonus and an inclusive availability window", %{
    conn: conn
  } do
    post_batch(conn, [open_operation(%{"group_id" => "group-1"})])

    result =
      post_batch(conn, [
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-01-03",
          "group_id" => "group-1",
          "amount_cents" => 10
        },
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-28",
          "group_id" => "group-1",
          "refund_method" => "hotel_credit"
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")
      |> List.last()

    assert result == %{
             "operation_id" => "cancel-1",
             "status" => "applied",
             "group_id" => "group-1",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 11,
             "revision" => 3
           }

    assert json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2028-02-28"), 200)["data"] ==
             %{
               "guest_id" => "guest-1",
               "available_cents" => 11,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-1",
                   "remaining_cents" => 11,
                   "expires_on" => "2028-02-29"
                 }
               ]
             }

    assert json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2028-02-29"), 200)["data"] ==
             %{"guest_id" => "guest-1", "available_cents" => 0, "lots" => []}

    assert json_response(get(conn, "/api/v1/ledger?on=2028-02-29"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 10,
             "credit_liability_cents" => 0
           }
  end

  test "applies credit by expiry and source, and checks stale revisions first", %{conn: conn} do
    post_batch(conn, [
      open_operation(%{
        "group_id" => "target",
        "arrival_on" => "2027-05-01",
        "departure_on" => "2027-05-02",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1500}]
      })
    ])

    credit_lot(%{
      source_operation_id: "z-source",
      remaining_cents: 100,
      expires_on: ~D[2027-06-01]
    })

    credit_lot(%{
      source_operation_id: "a-source",
      remaining_cents: 100,
      expires_on: ~D[2027-06-01]
    })

    assert apply_result(conn, %{
             "operation_id" => "apply-1",
             "type" => "apply_hotel_credit",
             "occurred_on" => "2027-01-03",
             "group_id" => "target",
             "amount_cents" => 150,
             "expected_revision" => 1
           })["revision"] == 2

    assert json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2027-01-03"), 200)["data"] ==
             %{
               "guest_id" => "guest-1",
               "available_cents" => 50,
               "lots" => [
                 %{
                   "source_operation_id" => "z-source",
                   "remaining_cents" => 50,
                   "expires_on" => "2027-06-01"
                 }
               ]
             }

    assert apply_result(conn, %{
             "operation_id" => "stale-apply",
             "type" => "apply_hotel_credit",
             "occurred_on" => "2027-01-03",
             "group_id" => "target",
             "amount_cents" => -1,
             "expected_revision" => 1
           }) == %{
             "operation_id" => "stale-apply",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "target",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert apply_result(conn, %{
             "operation_id" => "short-credit",
             "type" => "apply_hotel_credit",
             "occurred_on" => "2027-01-03",
             "group_id" => "target",
             "amount_cents" => 100,
             "expected_revision" => 2
           })["code"] == "insufficient_credit"

    assert apply_result(conn, %{
             "operation_id" => "apply-2",
             "type" => "apply_hotel_credit",
             "occurred_on" => "2027-01-03",
             "group_id" => "target",
             "amount_cents" => 50,
             "expected_revision" => 2
           })["revision"] == 3
  end

  test "uses the inclusive 30-day boundary and keeps advance purchase non-refundable", %{
    conn: conn
  } do
    post_batch(conn, [
      open_operation(%{
        "group_id" => "exactly-30",
        "arrival_on" => "2027-04-01"
      }),
      open_operation(%{
        "operation_id" => "open-29",
        "group_id" => "only-29",
        "arrival_on" => "2027-04-01"
      }),
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2027-04-01"
      })
    ])

    assert %{
             "policy_version" => "advance-nonrefundable",
             "refundable_until" => nil
           } = json_response(get(conn, "/api/v1/groups/advance"), 200)["data"]

    results =
      post_batch(conn, [
        %{
          "operation_id" => "pay-30",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-01-03",
          "group_id" => "exactly-30",
          "amount_cents" => 10
        },
        %{
          "operation_id" => "pay-29",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-01-03",
          "group_id" => "only-29",
          "amount_cents" => 10
        },
        %{
          "operation_id" => "pay-advance",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-01-03",
          "group_id" => "advance",
          "amount_cents" => 10
        },
        %{
          "operation_id" => "cancel-30",
          "type" => "cancel_group",
          "occurred_on" => "2027-03-02",
          "group_id" => "exactly-30"
        },
        %{
          "operation_id" => "cancel-29",
          "type" => "cancel_group",
          "occurred_on" => "2027-03-03",
          "group_id" => "only-29"
        },
        %{
          "operation_id" => "invalid-method",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "advance",
          "refund_method" => "points"
        },
        %{
          "operation_id" => "credit-method",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "advance",
          "refund_method" => "hotel_credit"
        },
        %{
          "operation_id" => "cancel-advance",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "advance"
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 3)["refunded_cents"] == 10
    assert Enum.at(results, 3)["retained_cents"] == 0
    assert Enum.at(results, 4)["refunded_cents"] == 0
    assert Enum.at(results, 4)["retained_cents"] == 10
    assert Enum.at(results, 5)["code"] == "invalid_refund_method"
    assert Enum.at(results, 6)["code"] == "refund_method_not_available"
    assert Enum.at(results, 7)["retained_cents"] == 10
  end

  test "splits group funding and restores applied credit only when refundable", %{conn: conn} do
    post_batch(conn, [open_operation(%{"group_id" => "refundable"})])
    credit_lot(%{source_operation_id: "original-credit", remaining_cents: 60})

    post_batch(conn, [
      %{
        "operation_id" => "cash-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-03",
        "group_id" => "refundable",
        "amount_cents" => 40
      },
      %{
        "operation_id" => "credit-pay",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-03",
        "group_id" => "refundable",
        "amount_cents" => 60
      },
      %{
        "operation_id" => "credit-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-04",
        "group_id" => "refundable",
        "refund_method" => "hotel_credit"
      }
    ])

    assert %{
             "cash_paid_cents" => 40,
             "credit_paid_cents" => 60,
             "status" => "cancelled"
           } = json_response(get(conn, "/api/v1/groups/refundable"), 200)["data"]

    assert json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2027-01-04"), 200)["data"] ==
             %{
               "guest_id" => "guest-1",
               "available_cents" => 104,
               "lots" => [
                 %{
                   "source_operation_id" => "original-credit",
                   "remaining_cents" => 60,
                   "expires_on" => "2027-06-01"
                 },
                 %{
                   "source_operation_id" => "credit-cancel",
                   "remaining_cents" => 44,
                   "expires_on" => "2028-01-05"
                 }
               ]
             }

    assert json_response(get(conn, "/api/v1/ledger?on=2027-01-04"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 40,
             "credit_liability_cents" => 104
           }
  end

  test "restores all partial applications from one lot", %{conn: conn} do
    post_batch(conn, [open_operation(%{"group_id" => "partial-restore"})])
    credit_lot(%{source_operation_id: "partial-source", remaining_cents: 60})

    post_batch(conn, [
      %{
        "operation_id" => "partial-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-03",
        "group_id" => "partial-restore",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "partial-2",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-04",
        "group_id" => "partial-restore",
        "amount_cents" => 10
      },
      %{
        "operation_id" => "partial-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-05",
        "group_id" => "partial-restore"
      }
    ])

    assert json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2027-01-05"), 200)["data"] ==
             %{
               "guest_id" => "guest-1",
               "available_cents" => 60,
               "lots" => [
                 %{
                   "source_operation_id" => "partial-source",
                   "remaining_cents" => 60,
                   "expires_on" => "2027-06-01"
                 }
               ]
             }
  end

  test "consumes credit on non-refundable cancellation and drops expired restoration", %{
    conn: conn
  } do
    post_batch(conn, [
      open_operation(%{
        "group_id" => "non-refundable",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      })
    ])

    credit_lot(%{source_operation_id: "consumed", remaining_cents: 20})

    post_batch(conn, [
      %{
        "operation_id" => "apply-consumed",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-03",
        "group_id" => "non-refundable",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "cancel-consumed",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-15",
        "group_id" => "non-refundable"
      }
    ])

    assert json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2027-02-15"), 200)["data"] ==
             %{"guest_id" => "guest-1", "available_cents" => 0, "lots" => []}

    post_batch(conn, [
      open_operation(%{
        "operation_id" => "open-expired-restore",
        "group_id" => "expired-restore",
        "arrival_on" => "2028-01-01",
        "departure_on" => "2028-01-02"
      })
    ])

    credit_lot(%{
      source_operation_id: "expired-original",
      remaining_cents: 20,
      expires_on: ~D[2027-06-01]
    })

    post_batch(conn, [
      %{
        "operation_id" => "apply-expired",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-03",
        "group_id" => "expired-restore",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "cancel-expired",
        "type" => "cancel_group",
        "occurred_on" => "2027-07-01",
        "group_id" => "expired-restore"
      }
    ])

    assert json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2027-07-01"), 200)["data"] ==
             %{"guest_id" => "guest-1", "available_cents" => 0, "lots" => []}

    assert json_response(get(conn, "/api/v1/ledger?on=2027-07-01"), 200)["data"][
             "credit_liability_cents"
           ] == 0
  end
end
