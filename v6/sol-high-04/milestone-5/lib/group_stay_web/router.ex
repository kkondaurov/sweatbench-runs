defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", GroupStayWeb do
    pipe_through :api

    post "/partner-batches", GroupStayController, :submit_batch
    get "/operations/:operation_id", GroupStayController, :show_operation
    get "/payments/:payment_operation_id", GroupStayController, :show_payment
    get "/groups/:group_id", GroupStayController, :show_group
    get "/guests/:guest_id/credit", GroupStayController, :guest_credit
    get "/ledger", GroupStayController, :ledger
  end
end
