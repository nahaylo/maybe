# An Interactive Brokers Flex Web Service token, and the Flex Query it runs.
#
# The token authenticates one IBKR login; the query (defined in Client Portal)
# decides which sections and which of the login's accounts the report covers.
# Together they are the unit of connection. A second login is a second row,
# with its own accounts.
class IbkrItem < ApplicationRecord
  # Guarded the same way PlaidItem and MonobankItem guard their tokens:
  # self-hosted instances often run without encryption keys configured.
  if Rails.application.credentials.active_record_encryption.present?
    encrypts :access_token, deterministic: true
  end

  belongs_to :family

  has_many :ibkr_accounts, dependent: :destroy
  has_many :accounts, through: :ibkr_accounts

  validates :name, :access_token, :query_id, presence: true
  validates :name, uniqueness: { scope: :family_id }

  scope :ordered, -> { order(:name) }

  def provider
    @provider ||= Provider::IbkrFlex.new(access_token)
  end

  # Namespaces this connection's cached statements. Two connections can run
  # queries with the same id under different logins.
  def cache_scope = id
end
