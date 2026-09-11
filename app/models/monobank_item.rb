# A Monobank API token, and everything reachable with it.
#
# A token belongs to exactly one Monobank client and can read only that client's
# accounts, so it is the unit of connection -- not a global setting. Two tokens
# (a second person, a second client) are two rows, each with its own accounts
# and its own rate limit.
class MonobankItem < ApplicationRecord
  # Guarded the same way PlaidItem guards its access token: self-hosted
  # instances often run without encryption keys configured.
  if Rails.application.credentials.active_record_encryption.present?
    encrypts :access_token, deterministic: true
  end

  belongs_to :family

  has_many :monobank_accounts, dependent: :destroy
  has_many :accounts, through: :monobank_accounts

  validates :name, :access_token, presence: true
  validates :name, uniqueness: { scope: :family_id }

  scope :ordered, -> { order(:name) }

  # Memoized on purpose. Provider::Monobank tracks the once-a-minute rate limit
  # in an instance variable, so a fresh client per request would reset the
  # cooldown to zero and 429 on the second call. One client per token, reused
  # for the whole run, is what makes the throttle work -- and it lets two
  # tokens run at full speed instead of queueing behind each other.
  def provider
    @provider ||= Provider::Monobank.new(access_token)
  end

  # Namespaces this item's cached client-info. Statement rows are keyed by
  # Monobank's own account ids, which are unique per client, but `client-info`
  # has no id in it -- without this a second token would overwrite the first's.
  def cache_scope = id
end
