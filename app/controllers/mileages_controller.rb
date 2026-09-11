class MileagesController < ApplicationController
  include EntryableResource, StreamExtensions

  def create
    account = Current.family.accounts.find(params.dig(:entry, :account_id))
    @entry = build_entry(account, entry_params)

    if @entry.save
      respond_to do |format|
        format.html { redirect_back_or_to account_path(account), notice: "Mileage recorded" }
        format.turbo_stream { stream_redirect_back_or_to(account_path(account), notice: "Mileage recorded") }
      end
    else
      @error_message = @entry.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  def update
    @entry.assign_attributes(entry_params.except(:unit))
    @entry.entryable.unit = entry_params[:unit] if entry_params[:unit].present?

    if @entry.save
      @entry.reload

      respond_to do |format|
        format.html { redirect_back_or_to account_path(@entry.account), notice: "Mileage updated" }
        format.turbo_stream { render turbo_stream: turbo_stream.replace(@entry) }
      end
    else
      @error_message = @entry.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  private
    def build_entry(account, params)
      account.entries.build(
        date: params[:date],
        amount: params[:amount],
        notes: params[:notes],
        currency: account.currency,
        name: "Odometer",
        entryable: Mileage.new(unit: params[:unit].presence || account.vehicle&.mileage_unit || "km")
      )
    end

    def entry_params
      params.require(:entry).permit(:date, :amount, :notes, :unit)
    end
end
