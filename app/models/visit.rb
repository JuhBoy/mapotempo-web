# Copyright © Mapotempo, 2016
#
# This file is part of Mapotempo.
#
# Mapotempo is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Mapotempo is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Mapotempo. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#
class Visit < ApplicationRecord
  belongs_to :destination
  has_many :stop_visits, inverse_of: :visit, dependent: :delete_all
  has_many :orders, inverse_of: :visit, dependent: :delete_all
  has_and_belongs_to_many :tags, after_add: :update_tags_track, after_remove: :update_tags_track
  delegate :lat, :lng, :name, :street, :postalcode, :city, :state, :country, :detail, :comment, :phone_number, to: :destination
  serialize :quantities, DeliverableUnitQuantity

  nilify_blanks
  validates :destination, presence: true

  include TimeAttr
  attribute :open1, ScheduleType.new
  attribute :close1, ScheduleType.new
  attribute :open2, ScheduleType.new
  attribute :close2, ScheduleType.new
  attribute :take_over, ScheduleType.new
  time_attr :open1, :close1, :open2, :close2, :take_over

  validate :close1_after_open1
  validates :close1, presence: true, if: :open2
  validate :close2_after_open2
  validate :open2_after_close1

  validate :quantities_validator

  include Consistency
  validate_consistency :tags, attr_consistency_method: ->(visit) { visit.destination.try :customer_id }

  before_save :update_tags, :create_orders
  before_update :update_out_of_date

  include RefSanitizer

  include LocalizedAttr

  attr_localized :quantities

  amoeba do
    exclude_association :stop_visits
    exclude_association :orders

    customize(lambda { |_original, copy|
      def copy.update_tags; end

      def copy.create_orders; end

      def copy.update_out_of_date; end
    })
  end

  # Custom validator for quantities. Mostly used by the destination model (:update, :create)
  def quantities_validator
    !quantities || quantities.values.each do |q|
      raise Exceptions::NegativeErrors.new(q, id, nested_attr: :quantities, record: self) if Float(q) < 0; # Raise both Float && NegativeErrors type
    end
  rescue StandardError => e
    self.errors.add(:quantities, :not_float) if e.is_a?(ArgumentError || TypeError)
    self.errors.add(:quantities, :negative_value, value: e.object[:value]) if e.is_a?(Exceptions::NegativeErrors)
  end

  def destroy
    # Too late to do this in before_destroy callback, children already destroyed
    Route.transaction do
      stop_visits.each{ |stop|
        stop.route.remove_stop(stop)
        stop.route.save
      }
    end
    super
  end

  def changed?
    @tag_ids_changed || super
  end

  def out_of_date
    Route.transaction do
      stop_visits.each{ |stop|
        stop.route.out_of_date = true
        stop.route.optimized_at = stop.route.last_sent_to = stop.route.last_sent_at = nil
        stop.route.save
      }
    end
  end

  def default_take_over
    take_over || destination.customer.take_over
  end

  def default_take_over_time_with_seconds
    take_over_time_with_seconds || destination.customer.take_over_time_with_seconds
  end

  def default_quantities
    @default_quantities ||= Hash[destination.customer.deliverable_units.collect{ |du|
      [du.id, quantities && quantities[du.id] ? quantities[du.id] : du.default_quantity]
    }]
    @default_quantities
  end

  def default_quantities?
    default_quantities && default_quantities.values.any?{ |q| q && q > 0 }
  end

  def quantities?
    quantities && quantities.values.any?{ |q| q }
  end

  def quantities_changed?
    quantities ? quantities.any?{ |i, q|
      !quantities_was || q != quantities_was[i]
    } : !!quantities_was
  end

  def color
    @color ||= (tags | destination.tags).find(&:color).try(&:color)
  end

  def icon
    @icon ||= (tags | destination.tags).find(&:icon).try(&:icon)
  end

  def default_color
    color || Destination::COLOR_DEFAULT
  end

  def default_icon
    icon || Destination::ICON_DEFAULT
  end

  def default_size
    nil
  end

  private

  def update_out_of_date
    if open1_changed? || close1_changed? || open2_changed? || close2_changed? || quantities_changed? || take_over_changed?
      out_of_date
    end
  end

  def update_tags_track(_tag)
    @tag_ids_changed = true
  end

  def tag_ids_changed?
    @tag_ids_changed
  end

  def update_tags
    if destination.customer && (@tag_ids_changed || new_record?)
      @tag_ids_changed = false

      # Don't use local collection here, not set when save new record
      destination.customer.plannings.each do |planning|
        if !new_record? && planning.visits.include?(self)
          if planning.tag_operation == 'or'
            unless (planning.tags.to_a & (tags.to_a | destination.tags.to_a)).present?
              planning.visit_remove(self)
            end
          else
            if planning.tags.to_a & (tags.to_a | destination.tags.to_a) != planning.tags.to_a
              planning.visit_remove(self)
            end
          end
        elsif planning.tag_operation == 'or' && (planning.tags.to_a & (tags.to_a | destination.tags.to_a)).present?
          planning.visit_add(self)
        elsif planning.tag_operation == 'and' && (planning.tags.to_a & (tags.to_a | destination.tags.to_a)) == planning.tags.to_a
          planning.visit_add(self)
        end
      end
    end

    true
  end

  def create_orders
    if destination.customer && new_record?
      destination.customer.order_arrays.each{ |order_array|
        order_array.add_visit(self)
      }
    end
  end

  def close1_after_open1
    if self.open1.present? && self.close1.present? && self.close1 < self.open1
      raise Exceptions::CLoseAndOpenErrors.new(nil, id, nested_attr: :close1, record: self)
    end
  rescue Exceptions::CLoseAndOpenErrors => e
    self.errors.add(:close1, :after, s: I18n.t('activerecord.attributes.visit.open1').downcase)
  end

  def close2_after_open2
    if self.open2.present? && self.close2.present? && self.close2 < self.open2
      raise Exceptions::CLoseAndOpenErrors.new(nil, id, nested_attr: :close2, record: self)
    end
  rescue Exceptions::CLoseAndOpenErrors => e
    self.errors.add(:close2, :after, s: I18n.t('activerecord.attributes.visit.open2').downcase)
  end

  def open2_after_close1
    if self.open2.present? && self.close1.present? && self.open2 < self.close1
      raise Exceptions::CLoseAndOpenErrors.new(nil, id, nested_attr: :close2, record: self)
    end
  rescue Exceptions::CLoseAndOpenErrors => e
    self.errors.add(:open2, :after, s: I18n.t('activerecord.attributes.visit.close1').downcase)
  end
end
