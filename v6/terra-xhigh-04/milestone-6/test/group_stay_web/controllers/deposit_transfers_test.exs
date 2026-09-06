defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: true

  import Phoenix.ConnTest

  test "moves mixed funding newest-first and fills destination rooms in order without changing totals",
       %{conn: conn} do
    results =
      post_operations(conn, [
        open_group("open-lot", "lot-source", "guest-1", [
          %{"room_id" => "lot-room", "nightly_rate_cents" => 5_000}
        ]),
        cash_payment("pay-lot", "lot-source", 1_000),
        cancel_group("cancel-lot", "lot-source", "hotel_credit"),
        open_group("open-source", "source", "guest-1", [
          %{"room_id" => "source-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "source-b", "nightly_rate_cents" => 10_000}
        ]),
        cash_payment("pay-source", "source", 1_000),
        hotel_credit("apply-source-credit", "source", 1_100),
        open_group("open-destination", "destination", "guest-1", [
          %{"room_id" => "destination-a", "nightly_rate_cents" => 5_000},
          %{"room_id" => "destination-b", "nightly_rate_cents" => 5_000}
        ]),
        transfer("move-mixed", "source", "destination", 1_600, %{
          "expected_revision" => 3,
          "destination_expected_revision" => 1
        })
      ])

    assert %{
             "operation_id" => "move-mixed",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 1_600,
             "source_outstanding_deposit_cents" => 3_500,
             "destination_outstanding_deposit_cents" => 400,
             "source_revision" => 4,
             "destination_revision" => 2
           } = Enum.at(results["results"], -1)

    assert %{
             "data" => %{
               "cash_paid_cents" => 500,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 3_500,
               "rooms" => [
                 %{"room_id" => "source-a", "cash_paid_cents" => 500, "credit_paid_cents" => 0},
                 %{"room_id" => "source-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
               ]
             }
           } = get(build_conn(), "/api/v1/groups/source") |> json_response(200)

    assert %{
             "data" => %{
               "cash_paid_cents" => 500,
               "credit_paid_cents" => 1_100,
               "outstanding_deposit_cents" => 400,
               "rooms" => [
                 %{
                   "room_id" => "destination-a",
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 1_000
                 },
                 %{
                   "room_id" => "destination-b",
                   "cash_paid_cents" => 500,
                   "credit_paid_cents" => 100
                 }
               ]
             }
           } = get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 1_000,
               "cash_converted_to_credit_cents" => 1_000,
               "credit_liability_cents" => 1_100
             }
           } = get(build_conn(), "/api/v1/ledger?on=2027-02-01") |> json_response(200)
  end

  test "resolves transfer validation and revisions in contract order and retries exactly", %{
    conn: conn
  } do
    post_operations(conn, [
      open_group("open-source", "source", "guest-1", one_room()),
      cash_payment("pay-source", "source", 1_000),
      open_group("open-destination", "destination", "guest-1", one_room())
    ])

    transfer_operation =
      transfer("move-once", "source", "destination", 600, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    assert %{
             "results" => [
               %{
                 "operation_id" => "move-once",
                 "status" => "applied",
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ]
           } = post_operations(build_conn(), [transfer_operation])

    assert %{
             "results" => [
               %{
                 "operation_id" => "move-once",
                 "status" => "applied",
                 "source_outstanding_deposit_cents" => 600,
                 "destination_outstanding_deposit_cents" => 400,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ]
           } = post_operations(build_conn(), [transfer_operation])

    assert %{"results" => [%{"code" => "group_not_found", "group_id" => "missing-source"}]} =
             post_operations(build_conn(), [
               transfer("missing-source", "missing-source", "destination", 1)
             ])

    assert %{"results" => [%{"code" => "group_not_found", "group_id" => "missing-destination"}]} =
             post_operations(build_conn(), [
               transfer("missing-destination", "source", "missing-destination", 1, %{
                 "expected_revision" => 0
               })
             ])

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "group_id" => "source",
                 "expected_revision" => 0,
                 "actual_revision" => 3
               }
             ]
           } =
             post_operations(build_conn(), [
               transfer("stale-source", "source", "destination", 1, %{
                 "expected_revision" => 0,
                 "destination_expected_revision" => 0
               })
             ])

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "group_id" => "destination",
                 "expected_revision" => 0,
                 "actual_revision" => 2
               }
             ]
           } =
             post_operations(build_conn(), [
               transfer("stale-destination", "source", "destination", 1, %{
                 "expected_revision" => 3,
                 "destination_expected_revision" => 0
               })
             ])

    assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 400}} =
             get(build_conn(), "/api/v1/groups/source") |> json_response(200)

    assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 600}} =
             get(build_conn(), "/api/v1/groups/destination") |> json_response(200)
  end

  test "payment corrections follow held cash across groups and bump each affected revision", %{
    conn: conn
  } do
    post_operations(conn, [
      open_group("open-alpha", "alpha", "guest-1", one_room()),
      cash_payment("pay-alpha", "alpha", 1_000),
      open_group("open-zeta", "zeta", "guest-1", one_room()),
      transfer("move-alpha", "alpha", "zeta", 600, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })
    ])

    assert %{
             "data" => %{
               "held_cents" => 1_000,
               "held_by_group" => [
                 %{"group_id" => "alpha", "amount_cents" => 400},
                 %{"group_id" => "zeta", "amount_cents" => 600}
               ]
             }
           } = get(build_conn(), "/api/v1/payments/pay-alpha") |> json_response(200)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "group_id" => "alpha",
                 "amount_cents" => 500,
                 "outstanding_deposit_cents" => 600,
                 "revision" => 4
               }
             ]
           } =
             post_operations(build_conn(), [
               reduce_cash("reduce-alpha", "pay-alpha", 500, 3)
             ])

    assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 100}} =
             get(build_conn(), "/api/v1/groups/zeta") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 500,
               "reduced_cents" => 500,
               "held_by_group" => [
                 %{"group_id" => "alpha", "amount_cents" => 400},
                 %{"group_id" => "zeta", "amount_cents" => 100}
               ]
             }
           } = get(build_conn(), "/api/v1/payments/pay-alpha") |> json_response(200)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "group_id" => "alpha",
                 "charged_back_cents" => 500,
                 "outstanding_deposit_cents" => 1_000,
                 "revision" => 5
               }
             ]
           } = post_operations(build_conn(), [charge_back("charge-alpha", "pay-alpha", 4)])

    assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 0}} =
             get(build_conn(), "/api/v1/groups/zeta") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 0,
               "reduced_cents" => 500,
               "charged_back_cents" => 500,
               "held_by_group" => []
             }
           } = get(build_conn(), "/api/v1/payments/pay-alpha") |> json_response(200)
  end

  test "rejects each transfer domain failure without moving funding", %{conn: conn} do
    post_operations(conn, [
      open_group("open-source", "source", "guest-1", one_room()),
      cash_payment("pay-source", "source", 1_000),
      open_group("open-destination", "destination", "guest-1", one_room()),
      cash_payment("pay-destination", "destination", 200),
      open_group("open-other-guest", "other-guest", "guest-2", one_room())
    ])

    assert %{
             "results" => [
               %{"code" => "invalid_transfer"},
               %{"code" => "invalid_transfer"},
               %{"code" => "invalid_amount"},
               %{"code" => "transfer_exceeds_held_funding"},
               %{"code" => "transfer_exceeds_outstanding"}
             ]
           } =
             post_operations(build_conn(), [
               transfer("same-group", "source", "source", 1),
               transfer("different-guest", "source", "other-guest", 1),
               transfer("bad-amount", "source", "destination", 0),
               transfer("too-much-held", "source", "destination", 1_001),
               transfer("too-much-outstanding", "source", "destination", 900)
             ])

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"code" => "group_not_active", "group_id" => "destination"}
             ]
           } =
             post_operations(build_conn(), [
               cancel_group("cancel-destination", "destination", "cash"),
               transfer("inactive-destination", "source", "destination", 1)
             ])

    assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 1_000}} =
             get(build_conn(), "/api/v1/groups/source") |> json_response(200)
  end

  test "settles transferred cash by the destination policy and restores transferred credit to its lot",
       %{conn: conn} do
    post_operations(conn, [
      open_group("open-cash-source", "cash-source", "guest-1", one_room(), %{
        "rate_plan" => "advance_purchase"
      }),
      cash_payment("pay-cash-source", "cash-source", 5_000),
      open_group("open-cash-destination", "cash-destination", "guest-1", [
        %{"room_id" => "cash-destination-room", "nightly_rate_cents" => 5_000}
      ]),
      transfer("move-cash", "cash-source", "cash-destination", 1_000, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }),
      cancel_group("cancel-cash-destination", "cash-destination", "hotel_credit"),
      open_group("open-credit-lot", "credit-lot", "guest-1", one_room()),
      cash_payment("pay-credit-lot", "credit-lot", 1_000),
      cancel_group("cancel-credit-lot", "credit-lot", "hotel_credit"),
      open_group("open-credit-source", "credit-source", "guest-1", one_room()),
      hotel_credit("apply-credit-source", "credit-source", 1_000),
      open_group("open-credit-destination", "credit-destination", "guest-1", one_room()),
      transfer("move-credit", "credit-source", "credit-destination", 1_000, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }),
      cancel_group("cancel-credit-destination", "credit-destination", "cash")
    ])

    assert %{
             "data" => %{
               "held_cents" => 4_000,
               "converted_to_credit_cents" => 1_000,
               "held_by_group" => [%{"group_id" => "cash-source", "amount_cents" => 4_000}]
             }
           } = get(build_conn(), "/api/v1/payments/pay-cash-source") |> json_response(200)

    assert %{
             "data" => %{
               "guest_id" => "guest-1",
               "available_cents" => 2_200,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-cash-destination",
                   "remaining_cents" => 1_100
                 },
                 %{"source_operation_id" => "cancel-credit-lot", "remaining_cents" => 1_100}
               ]
             }
           } =
             get(build_conn(), "/api/v1/guests/guest-1/credit?on=2027-01-05")
             |> json_response(200)
  end

  defp open_group(operation_id, group_id, guest_id, rooms, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-10",
        "departure_on" => "2027-04-11",
        "rate_plan" => "flexible",
        "rooms" => rooms
      },
      overrides
    )
  end

  defp one_room, do: [%{"room_id" => "room-a", "nightly_rate_cents" => 5_000}]

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp hotel_credit(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_group(operation_id, group_id, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2027-01-05",
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp transfer(
         operation_id,
         source_group_id,
         destination_group_id,
         amount_cents,
         overrides \\ %{}
       ) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "transfer_deposit",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp reduce_cash(operation_id, payment_operation_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp charge_back(operation_id, payment_operation_id, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end

  defp post_operations(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end
end
