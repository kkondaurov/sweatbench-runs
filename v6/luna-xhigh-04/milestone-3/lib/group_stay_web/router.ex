defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", GroupStayWeb do
    pipe_through :api

    scope "/v1" do
      post "/partner-batches", PartnerBatchController, :create
      get "/operations/:operation_id", OperationController, :show
      get "/groups/:group_id", GroupController, :show
      get "/ledger", LedgerController, :show
      get "/guests/:guest_id/credit", GuestCreditController, :show
    end
  end
end
