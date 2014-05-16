$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require 'active_record'
require 'active_support/core_ext'
require 'active_support/cache'
require 'identity_cache'
require 'memcached_store'
require 'active_support/cache/memcached_store'

$memcached_port = 11211
$mysql_port = 3306

require File.dirname(__FILE__) + '/../test/helpers/active_record_objects'
require File.dirname(__FILE__) + '/../test/helpers/database_connection'

IdentityCache.logger = Logger.new(nil)
IdentityCache.cache_backend = ActiveSupport::Cache::MemcachedStore.new("localhost:#{$memcached_port}", :support_cas => true)


def create_record(id)
  Item.new(id)
end

def database_ready(count)
  Item.where(:id => (1..count)).count == count
rescue
  false
end

def create_database(count)
  DatabaseConnection.setup

  helper = Object.new.extend(ActiveRecordObjects)
  helper.setup_models

  return if database_ready(count)
  puts "Database not ready for performance testing, generating records"

  DatabaseConnection.drop_tables
  DatabaseConnection.create_tables
  existing = Item.all
  (1..count).to_a.each do |i|
    unless existing.any? { |e| e.id == i }
      a = Item.new
      a.id = i
      a.associated = AssociatedRecord.new(name: "Associated for #{i}")
      a.associated_records
      (1..5).each do |j|
        a.associated_records << AssociatedRecord.new(name: "Has Many #{j} for #{i}")
        a.normalized_associated_records << NormalizedAssociatedRecord.new(name: "Normalized Has Many #{j} for #{i}")
      end
      a.save
    end
  end
ensure
  helper.teardown_models
end

def setup_embedded_associations
  Item.cache_has_one :associated
  Item.cache_has_many :associated_records, :embed => true
  AssociatedRecord.cache_has_many :deeply_associated_records, :embed => true
end

class CacheRunner
  include ActiveRecordObjects
  include DatabaseConnection

  def initialize(count)
    @count = count
  end

  def prepare
    setup_models
  end

  def cleanup
    teardown_models
  end
end

CACHE_RUNNERS = []

class FindRunner < CacheRunner
  def run
    (1..@count).each do |i|
      ::Item.includes(:associated, {:associated_records => :deeply_associated_records}).find(i)
    end
  end
end
CACHE_RUNNERS << FindRunner

module MissRunner
  def prepare
    super
    IdentityCache.cache.clear
  end
end

module HitRunner
  def prepare
    super
    run
  end
end

class EmbedRunner < CacheRunner
  def setup_models
    super
    Item.cache_has_one :associated
    Item.cache_has_many :associated_records, :embed => true
    AssociatedRecord.cache_has_many :deeply_associated_records, :embed => true
  end

  def run
    (1..@count).each do |i|
      rec = ::Item.fetch(i)
      rec.fetch_associated
      rec.fetch_associated_records
    end
  end
end

class FetchEmbedMissRunner < EmbedRunner
  include MissRunner
end
CACHE_RUNNERS << FetchEmbedMissRunner

class FetchEmbedHitRunner < EmbedRunner
  include HitRunner
end
CACHE_RUNNERS << FetchEmbedHitRunner


class NormalizedRunner < CacheRunner
  def setup_models
    super
    Item.cache_has_one :associated # :embed => false isn't supported
    Item.cache_has_many :associated_records, :embed => :ids
    AssociatedRecord.cache_has_many :deeply_associated_records, :embed => :ids
  end

  def run
    (1..@count).each do |i|
      rec = ::Item.fetch(i)
      rec.fetch_associated
      associated_records = rec.fetch_associated_records
      # FIXME: Only fetch_multi has :includes support, so use what it uses internally
      AssociatedRecord.send(:prefetch_associations, :deeply_associated_records, associated_records)
    end
  end
end

class FetchNormalizedMissRunner < NormalizedRunner
  include MissRunner
end
CACHE_RUNNERS << FetchNormalizedMissRunner

class FetchNormalizedHitRunner < NormalizedRunner
  include HitRunner
end
CACHE_RUNNERS << FetchNormalizedHitRunner
