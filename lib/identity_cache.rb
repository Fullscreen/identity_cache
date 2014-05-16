require 'active_record'
require 'active_support/core_ext/module/attribute_accessors'
require 'ar_transaction_changes'

require "identity_cache/version"
require 'identity_cache/memoized_cache_proxy'
require 'identity_cache/belongs_to_caching'
require 'identity_cache/cache_key_generation'
require 'identity_cache/configuration_dsl'
require 'identity_cache/parent_model_expiration'
require 'identity_cache/query_api'
require "identity_cache/cache_hash"
require "identity_cache/cache_invalidation"

module IdentityCache
  CACHED_NIL = :idc_cached_nil
  BATCH_SIZE = 1000
  DELETED = :idc_cached_deleted
  DELETED_TTL = 1000

  class AlreadyIncludedError < StandardError; end
  class InverseAssociationError < StandardError
    def initialize
      super "Inverse name for association could not be determined. Please use the :inverse_name option to specify the inverse association name for this cache."
    end
  end

  class << self
    include IdentityCache::CacheHash

    attr_accessor :readonly
    attr_writer :logger

    mattr_accessor :cache_namespace
    self.cache_namespace = "IDC:#{CACHE_VERSION}:".freeze

    def included(base) #:nodoc:
      raise AlreadyIncludedError if base.respond_to? :cache_indexes

      base.send(:include, ArTransactionChanges) unless base.include?(ArTransactionChanges)
      base.send(:include, IdentityCache::BelongsToCaching)
      base.send(:include, IdentityCache::CacheKeyGeneration)
      base.send(:include, IdentityCache::ConfigurationDSL)
      base.send(:include, IdentityCache::QueryAPI)
      base.send(:include, IdentityCache::CacheInvalidation)
    end

    # Sets the cache adaptor IdentityCache will be using
    #
    # == Parameters
    #
    # +cache_adaptor+ - A ActiveSupport::Cache::Store
    #
    def cache_backend=(cache_adaptor)
      if @cache
        cache.cache_backend = cache_adaptor
      else
        @cache = MemoizedCacheProxy.new(cache_adaptor)
      end
    end

    def cache
      @cache ||= MemoizedCacheProxy.new
    end

    def logger
      @logger || Rails.logger
    end

    def should_cache? # :nodoc:
      !readonly && ActiveRecord::Base.connection.open_transactions == 0
    end

    # Cache retrieval and miss resolver primitive; given a key it will try to
    # retrieve the associated value from the cache otherwise it will return the
    # value of the execution of the block.
    #
    # == Parameters
    # +key+ A cache key string
    #
    def fetch(key)
      return block_given? ? yield : nil unless should_cache?
      return cache.read(key) unless block_given?

      result = cache.fetch(key) { map_cached_nil_for yield }
      unmap_cached_nil_for(result)
    end

    def map_cached_nil_for(value)
      value.nil? ? IdentityCache::CACHED_NIL : value
    end

    def unmap_cached_nil_for(value)
      value == IdentityCache::CACHED_NIL ? nil : value
    end

    # Same as +fetch+, except that it will try a collection of keys, using the
    # multiget operation of the cache adaptor.
    #
    # == Parameters
    # +keys+ A collection or array of key strings
    def fetch_multi(*keys)
      keys.flatten!(1)
      return {} if keys.size == 0

      result = if should_cache? && block_given?
        fetch_in_batches(keys) do |missed_keys|
          results = yield missed_keys
          results.map {|e| map_cached_nil_for e }
        end
      elsif should_cache?
        read_in_batches(keys)
      elsif block_given?
        results = yield keys
        keys.zip(results).to_h
      else
        {}
      end

      result.each do |key, value|
        result[key] = unmap_cached_nil_for(value)
      end

      result
    end

    private

    def read_in_batches(keys)
      keys.each_slice(BATCH_SIZE).each_with_object Hash.new do |slice, result|
        result.merge! cache.read_multi(*slice)
      end
    end

    def fetch_in_batches(keys)
      keys.each_slice(BATCH_SIZE).each_with_object Hash.new do |slice, result|
        result.merge! cache.fetch_multi(*slice) {|missed_keys| yield missed_keys }
      end
    end
  end
end
