module SwitchNamespace

  module ClassMethods
    def rails_cache_key_namespace
      "#{self.namespace}:#{super}"
    end
  end

  def self.included(base)
    base.extend ClassMethods
    base.class_eval do
      class_attribute :namespace
      self.namespace = 'ns'
    end
  end
end

module ActiveRecordObjects

  def setup_models(base = ActiveRecord::Base)
    Object.send :const_set, 'DeeplyAssociatedRecord', Class.new(base) {
      include IdentityCache
      belongs_to :associated_record
      default_scope { order('name DESC') }
    }

    Object.send :const_set, 'AssociatedRecord', Class.new(base) {
      include IdentityCache
      belongs_to :record
      has_many :deeply_associated_records
      default_scope { order('id DESC') }
    }

    Object.send :const_set, 'NormalizedAssociatedRecord', Class.new(base) {
      include IdentityCache
      belongs_to :record
      default_scope { order('id DESC') }
    }

    Object.send :const_set, 'NotCachedRecord', Class.new(base) {
      belongs_to :record, :touch => true
      default_scope { order('id DESC') }
    }

    Object.send :const_set, 'PolymorphicRecord', Class.new(base) {
      belongs_to :owner, :polymorphic => true
    }

    Object.send :const_set, 'Record', Class.new(base) {
      include IdentityCache
      belongs_to :record
      has_many :associated_records
      has_many :normalized_associated_records
      has_many :not_cached_records
      has_many :polymorphic_records, :as => 'owner'
      has_one :polymorphic_record, :as => 'owner'
      has_one :associated, :class_name => 'AssociatedRecord'
    }
  end

  def teardown_models
    ActiveSupport::DescendantsTracker.clear
    ActiveSupport::Dependencies.clear
    Object.send :remove_const, 'DeeplyAssociatedRecord'
    Object.send :remove_const, 'PolymorphicRecord'
    Object.send :remove_const, 'NormalizedAssociatedRecord'
    Object.send :remove_const, 'AssociatedRecord'
    Object.send :remove_const, 'NotCachedRecord'
    Object.send :remove_const, 'Record'
  end
end
