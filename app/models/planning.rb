# Copyright © Mapotempo, 2013-2017
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
class Planning < ApplicationRecord
  default_scope { includes(:tags).order(:id) }

  belongs_to :customer
  has_and_belongs_to_many :zonings, autosave: true, after_add: :update_zonings_track, after_remove: :update_zonings_track
  has_many :routes, -> { order('CASE WHEN vehicle_usage_id IS NULL THEN 0 ELSE routes.id END') }, inverse_of: :planning, autosave: true, dependent: :delete_all
  has_and_belongs_to_many :tags, autosave: true, after_add: :update_tags_track, after_remove: :update_tags_track
  belongs_to :order_array
  belongs_to :vehicle_usage_set, inverse_of: :plannings, validate: true

  nilify_blanks
  auto_strip_attributes :name

  enum tag_operation: [:and, :or]

  validates :customer, presence: true
  validates :name, presence: true
  validates :vehicle_usage_set, presence: true
  validates :begin_date, presence: true, if: :end_date
  validates :end_date, presence: true, if: :begin_date
  validate :begin_after_end_date

  include Consistency
  validate_consistency :vehicle_usage_set, :order_array, :zonings, :tags

  before_create :update_zonings, :check_max_planning
  before_save :update_vehicle_usage_set

  include RefSanitizer

  amoeba do
    enable

    customize(lambda { |_original, copy|
      def copy.update_zonings; end

      def copy.update_vehicle_usage_set; end

      copy.routes.each{ |route|
        route.planning = copy
      }
    })
  end

  def duplicate
    copy = self.amoeba_dup
    copy.name += " (#{I18n.l(Time.zone.now, format: :long)})"
    copy
  end

  def changed?
    routes_changed? || super
  end

  def set_routes(routes_visits, recompute = true, ignore_errors = false)
    default_empty_routes(ignore_errors)
    routes_visits = routes_visits.select{ |ref, _d| ref } # Remove out_of_route
    if routes_visits.size <= routes.size - 1
      visits = routes_visits.values.flat_map{ |s| s[:visits] }.collect{ |visit_active| visit_active[0] }
      # Set all excluded visits out of route
      routes.find{ |r| !r.vehicle_usage? }.set_visits((customer.visits - visits).select{ |visit|
        tags_compatible?(visit.tags.to_a | visit.destination.tags.to_a)
      })

      index_routes = (1..routes.size).to_a
      routes_visits.each{ |_ref, r|
        index_routes.delete(routes.index{ |rr| rr.vehicle_usage? && rr.vehicle_usage.vehicle.ref == r[:ref_vehicle] }) if r[:ref_vehicle]
      }
      routes_visits.each{ |ref, r|
        i = routes.index{ |rr| r[:ref_vehicle] && rr.vehicle_usage? && rr.vehicle_usage.vehicle.ref == r[:ref_vehicle] } || index_routes.shift
        routes[i].ref = ref
        routes[i].set_visits(r[:visits].select{ |visit|
          tags_compatible?(visit[0].tags.to_a | visit[0].destination.tags.to_a)
        }, recompute, ignore_errors)
      }
      true
    else
      false
    end
  end

  def vehicle_usage_add(vehicle_usage, ignore_errors = false)
    route = routes.build(vehicle_usage: vehicle_usage, outdated: false)
    vehicle_usage.routes << route unless vehicle_usage.id
    route.init_stops(true, ignore_errors)
  end

  def vehicle_usage_remove(vehicle_usage)
    route = routes.find{ |route| route.vehicle_usage == vehicle_usage}
    # route no longer exists if vehicle is disabled
    if route
      out_of_route = routes.find{ |r| !r.vehicle_usage? }
      route.stops.select{ |stop| stop.is_a?(StopVisit) }.map{ |stop|
        out_of_route.stops.build(type: StopVisit.name, visit: stop.visit, index: out_of_route.stops.length + 1)
      }
      routes.destroy(route)
    end
  end

  def visit_add(visit)
    update_routes_changed
    routes.find{ |r| !r.vehicle_usage? }.add(visit)
  end

  def visit_remove(visit)
    update_routes_changed
    routes.each{ |route|
      route.remove_visit(visit)
    }
  end

  def default_empty_routes(ignore_errors = false)
    routes.clear
    routes.build
    vehicle_usage_set.vehicle_usages.select(&:active).each { |vehicle_usage|
      vehicle_usage_add(vehicle_usage, ignore_errors)
    }
  end

  def default_routes
    if vehicle_usage_set && routes.length != vehicle_usage_set.vehicle_usages.select(&:active).length + 1
      default_empty_routes

      if !split_by_zones(visits_compatibles)
        routes.find{ |r| !r.vehicle_usage? }.default_stops
      end
    end
  end

  def compute(options = {})
    routes.each{ |r| r.compute(options) }
  end

  def switch(route, vehicle_usage)
    previous_route = routes.find{ |route| route.vehicle_usage == vehicle_usage }
    if previous_route
      need_fetch_stop_status = previous_route.stops.any?(&:status)

      previous_vehicle_usage = route.vehicle_usage
      route.vehicle_usage = vehicle_usage
      previous_route.vehicle_usage = previous_vehicle_usage

      # Rest sticky with vehicle_usage
      previous_rests = previous_route.stops.select{ |stop| stop.is_a?(StopRest) }
      rests = route.stops.select{ |stop| stop.is_a?(StopRest) }
      previous_rests.each{ |rest|
        move_stop(route, rest, -1, true)
      }
      rests.each{ |rest|
        move_stop(previous_route, rest, -1, true)
      }

      fetch_stops_status if need_fetch_stop_status

      true
    else
      false
    end
  end

  def move_visit(route, visit, index)
    stop = nil
    routes.find do |route|
      route.stops.find{ |s| stop = s if s.is_a?(StopVisit) && s.visit == visit }
    end

    # stop = Stop.where(route_id: self.routes.ids, visit_id: visit.id, type: 'StopVisit')
    if stop
      move_stop(route, stop, index)
    end
  end

  def move_stop(route, stop, index, force = false)
    route, index = prefered_route_and_index([route], stop) unless index || !route.vehicle_usage?
    if stop.route != route
      if stop.is_a?(StopVisit)
        visit, active = stop.visit, stop.active
        stop_id = stop.id
        stop.route.move_stop_out(stop)
        route.add(visit, index || 1, active || stop.route.vehicle_usage.nil?, stop_id)
      elsif force && stop.is_a?(StopRest)
        active = stop.active
        stop_id = stop.id
        stop.route.move_stop_out(stop, force)
        route.add_rest(active, stop_id)
      end
    else
      route.move_stop(stop, index || 1)
    end
  end

  # Available options:
  # out_of_zone (true by default)
  # active_only (true by default, only for prefered_route_and_index)
  # max_time
  # max_distance
  def automatic_insert(stop, options = {})
    options[:out_of_zone] = true if options[:out_of_zone] == nil

    available_routes = []

    # If already in route, stay in route
    if stop.route.vehicle_usage?
      available_routes = [stop.route]
    end

    # If zoning, get appropriate route
    if available_routes.empty? && !zonings.empty?
      zone = Zoning.new(zones: zonings.collect(&:zones).flatten).inside(stop.visit.destination)
      if zone && zone.vehicle
        route = routes.find{ |route|
          route.vehicle_usage? && route.vehicle_usage.vehicle == zone.vehicle && !route.locked
        }
        (available_routes = [route]) if route
      end
    end

    # If still no route get all routes matching skills
    tags = stop.is_a?(StopVisit) ? (stop.visit.destination.tags | stop.visit.tags) : nil
    if available_routes.empty? && options[:out_of_zone]
      skill_tags = all_skills & tags
      available_routes = routes.select{ |route|
        next unless route.vehicle_usage?

        if !skill_tags.empty?
          common_tags = [route.vehicle_usage.tags, route.vehicle_usage.vehicle.tags].flatten & tags
          !route.locked && !common_tags.empty?
        else
          !route.locked
        end
      }
    end

    # So, no target route, nothing to do
    if available_routes.empty?
      return
    end

    # Take the closest routes visit and eval insert
    route, index = prefered_route_and_index(available_routes, stop, options)

    if route
      stop.active = true
      move_stop(route, stop, index || 1)
      return route
    end
  end

  def outdated
    routes.inject(false){ |acc, route|
      acc || route.outdated
    }
  end

  def tags_compatible?(tags_)
    if self.tag_operation == 'or'
      (tags_.to_a & tags.to_a).present?
    else
      (tags_.to_a & tags.to_a).size == tags.size
    end
  end

  def visits_compatibles
    if self.tag_operation == 'or'
      customer.visits.select { |visit|
        (tags.to_a & (visit.tags.to_a | visit.destination.tags.to_a)).present?
      }
    else
      customer.visits.select { |visit|
        tags.to_a & (visit.tags.to_a | visit.destination.tags.to_a) == tags.to_a
      }
    end
  end

  def visits
    routes.collect{ |route|
      route.stops.select{ |stop| stop.is_a?(StopVisit) }.collect(&:visit)
    }.flatten
  end

  def apply_orders(order_array, shift)
    orders = order_array.orders.select{ |order|
      order.shift == shift && !order.products.empty?
    }.collect{ |order|
      [order.visit_id, order.products]
    }
    orders = Hash[orders]

    routes.each{ |route|
      if route.vehicle_usage?
        route.stops.each{ |stop|
          stop.active = orders.key?(stop.visit_id) && !orders[stop.visit_id].empty?
        }
      end
      route.outdated = true
    }

    self.order_array = order_array
    self.date = order_array.base_date + shift
  end

  def split_by_zones(visits_free)
    self.zoning_outdated = false
    @zoning_ids_changed = false
    if !zonings.empty? && !routes.empty?
      # Make sure there is at least one Zone with Vehicle, else, don't apply Zones
      return unless zonings.any?{ |zoning| zoning.zones.any?{ |zone| !zone.avoid_zone && !zone.vehicle_id.blank? } }

      need_fetch_stop_status = routes.any?{ |r| r.stops.any?(&:status) }

      vehicles_map = Hash[routes.group_by(&:vehicle_usage).map { |vehicle_usage, routes|
        next if vehicle_usage && !vehicle_usage.active?
        [vehicle_usage && vehicle_usage.vehicle, routes[0]]
      }]

      Planning.transaction do
        # Get free visits if not the first initial split on planning building
        if !visits_free
          visits_free = routes.reject(&:locked).flat_map(&:stops).select{ |stop| stop.is_a?(StopVisit) }.map(&:visit)

          routes.each{ |route|
            route.locked || route.set_visits([])
          }
        end

        Zoning.new(zones: zonings.collect(&:zones).flatten).apply(visits_free).each{ |zone, visits|
          if zone && zone.vehicle && vehicles_map[zone.vehicle] && !vehicles_map[zone.vehicle].locked
            vehicles_map[zone.vehicle].add_visits(visits.collect{ |d| [d, true] })
          else
            # Add to unplanned route even if the route is locked
            routes.find{ |r| !r.vehicle_usage? }.add_visits(visits.collect{ |d| [d, true] })
          end
        }
      end

      fetch_stops_status if need_fetch_stop_status

      true
    end
  end

  def optimize(routes, option = { global: false, active_only: true, ignore_overload_multipliers: [] }, &optimizer)
    routes_with_vehicle = routes.select(&:vehicle_usage?)
    stops_on = (routes.find{ |r| !r.vehicle_usage? }.try(:stops) || []) + routes_with_vehicle.flat_map{ |r|
      r.stops_segregate(option[:active_only])[true]
    }.compact

    o = amalgamate_stops_same_position(stops_on, option[:global], routes_with_vehicle.map(&:vehicle_usage)) { |positions|
      services_and_rests = positions.collect{ |position|
        stop_id, open1, close1, open2, close2, priority, duration, vehicle_usage_id, quantities, quantities_operations, skills, rest = position[2..13]
        if option[:ignore_overload_multipliers] && quantities
          quantities.select!{ |id, _val|
            option[:ignore_overload_multipliers].find{ |iom| iom[:unit_id] == id if iom[:ignore] }.nil?
          }
        end

        {stop_id: stop_id, start1: open1, end1: close1, start2: open2, end2: close2, priority: priority, duration: duration, vehicle_usage_id: vehicle_usage_id, quantities: quantities, quantities_operations: quantities_operations, skills: skills, rest: rest}
      }

      unnil_positions(positions, services_and_rests) { |positions, services, rests|
        positions = positions.collect{ |position| position[0..1] }
        vehicles = routes_with_vehicle.collect{ |r|
          position_start = r.vehicle_usage.default_store_start.try(&:position?) ? [r.vehicle_usage.default_store_start.lat, r.vehicle_usage.default_store_start.lng] : nil
          position_stop = r.vehicle_usage.default_store_stop.try(&:position?) ? [r.vehicle_usage.default_store_stop.lat, r.vehicle_usage.default_store_stop.lng] : nil
          # TODO: simplify positions without duplications (for instance same start and stop stores)
          positions = (positions + [position_start, position_stop]).compact

          vehicle_open = r.vehicle_usage.default_open
          vehicle_open += r.vehicle_usage.default_service_time_start if r.vehicle_usage.default_service_time_start
          vehicle_close = r.vehicle_usage.default_close
          vehicle_close -= r.vehicle_usage.default_service_time_end if r.vehicle_usage.default_service_time_end
          vehicle_skills = [r.vehicle_usage.tags, r.vehicle_usage.vehicle.tags].flatten.compact.map(&:label)
          vehicle_time = r.vehicle_usage.default_work_time(true)
          {
            id: r.vehicle_usage_id,
            router: r.vehicle_usage.vehicle.default_router,
            router_dimension: r.vehicle_usage.vehicle.default_router_dimension,
            router_options: r.vehicle_usage.vehicle.default_router_options.symbolize_keys.except(:time, :distance, :isochrone, :isodistance, :avoid_zones),
            speed_multiplier: r.vehicle_usage.vehicle.default_speed_multiplier,
            speed_multiplier_areas: Zoning.speed_multiplier_areas(zonings),
            open: vehicle_open.to_f,
            close: vehicle_close.to_f,
            work_time: vehicle_time && vehicle_time.to_f,
            max_distance: r.vehicle_usage.vehicle.max_distance,
            stores: [position_start && :start, position_stop && :stop].compact,
            rests: rests.select{ |s| s[:vehicle_usage_id] == r.vehicle_usage_id },
            capacities: r.vehicle_usage.vehicle.default_capacities && r.vehicle_usage.vehicle.default_capacities.each.map{ |k, v|
              capacity = option[:ignore_overload_multipliers].find{ |iom| iom[:unit_id] == k } if option[:ignore_overload_multipliers]
              {
                deliverable_unit_id: k,
                capacity: capacity.nil? ? v : capacity[:ignore] ? nil : v,
                overload_multiplier: customer.deliverable_units.find{ |du| du.id == k }.optimization_overload_multiplier || Mapotempo::Application.config.optimize_overload_multiplier
              }
            },
            skills: vehicle_skills
          }
        }
        # Remove out-of-route if no global optimization
        optimizer.call(positions, services, vehicles)[(routes.find{ |r| !r.vehicle_usage? } ? 0 : 1)..-1]
      }
    }
    routes_with_vehicle.each_with_index{ |r, i|
      if o[routes.find{ |route| !route.vehicle_usage? } ? i + 1 : i].size > 0
        r.optimized_at = Time.now.utc
        r.last_sent_to = r.last_sent_at = nil
      elsif option[:global]
        r.optimized_at = r.last_sent_to = r.last_sent_at = nil
      end
    }
    o
  end

  def set_stops(routes, stop_ids, active_only = true)
    raise 'Invalid routes count' unless routes.size == stop_ids.size
    Route.transaction do
      stops_count = routes.collect{ |r| r.stops.size }.reduce(&:+)
      flat_stop_ids = stop_ids.flatten.compact
      inactive_stop_ids = []

      routes.select(&:vehicle_usage?).each do |route|
        inactive_stop_ids += route.stops.reject(&:active).map(&:id)
      end

      routes.each_with_index{ |route, index|
        stops_ = route.stops_segregate(active_only) # Split stops according to stop active statement

        # Get ordered stops in current route
        ordered_stops = routes.flat_map{ |r| r.stops.select{ |s| stop_ids[index].include? s.id } }.sort_by{ |s| stop_ids[index].index s.id }

        # 1. Set route and index (active stops returned by optim for instance)
        i = 0
        ordered_stops.each{ |stop|
          # Don't change route for rests, but build index
          if stop.is_a?(StopRest) && !route.vehicle_usage?
            flat_stop_ids.delete stop.id
          else
            stop.active = true if route.vehicle_usage? && inactive_stop_ids.exclude?(stop.id)
            stop.index = i += 1
            stop.time = stop.distance = stop.drive_time = stop.out_of_window = stop.out_of_capacity = stop.out_of_drive_time = stop.out_of_work_time = stop.out_of_max_distance = nil
            if stop.route_id != route.id
              stop.route_id = route.id
              stop.save!
            end
          end
        }

        # 2. Set index and active for other stops (inactive or not in optim for instance)
        other_inactive_stops = (stops_[true] ? stops_[true].select{ |s| s.route_id == route.id && flat_stop_ids.exclude?(s.id) }.sort_by(&:index) : []) - ordered_stops + (stops_[false] ? stops_[false].sort_by(&:index) : [])
        other_inactive_stops.each{ |stop|
          stop.active = false if route.vehicle_usage?
          stop.index = i += 1
          stop.time = stop.distance = stop.drive_time = stop.out_of_window = stop.out_of_capacity = stop.out_of_drive_time = stop.out_of_work_time = stop.out_of_max_distance = nil
        }
      }

      # Save route to update now stop.route_id
      routes.each{ |route|
        route.outdated = true
        (route.no_stop_index_validation = true) && route.save!
        route.stops.reload # Refresh route.stops collection if stops have been moved
      }
      raise 'Invalid stops count' unless routes.collect{ |r| r.stops.size }.reduce(&:+) == stops_count
      self.reload # Refresh route.stops collection if stops have been moved
    end
  end

  def fetch_stops_status
    Visit.transaction do
      if customer.enable_stop_status
        stops_map = Hash[routes.select(&:vehicle_usage?).flat_map(&:stops).map { |stop| [(stop.is_a?(StopVisit) ? "v#{stop.visit_id}" : "r#{stop.id}"), stop] }]
        stops_map.each { |ss| ss[1].assign_attributes status: nil, eta: nil }
        routes.each(&:clear_eta_data)
        routes_quantities_changed = []

        stops_status = Mapotempo::Application.config.devices.each_pair.flat_map { |key, device|
          if device.respond_to?(:fetch_stops) && customer.device.configured?(key)
            device.fetch_stops(self.customer, device.planning_date(self), self) rescue nil
          end
        }.compact.select { |s|

          # Update ETA on Routes
          if !DeviceBase.is_a_store?(s[:order_id])
            true
          else
            if DeviceBase.is_fleet_hash?(s)
              attr = if DeviceBase.is_arrival?(s)
                {
                  arrival_eta: s[:eta],
                  arrival_status: s[:status]
                }
              else
                {
                  departure_eta: s[:eta],
                  departure_status: s[:status]
                }
              end
              route = routes.select { |r| r.id == s[:route_id].to_i }.first
              route && route.assign_attributes(attr)
            end

            false
          end
        }.each { |s|
          if stops_map.key?(s[:order_id])
            if !s[:quantities].nil? && s[:quantities].is_a?(Array)
              quantities = {}
              du_by_label = {}
              customer.deliverable_units.map { |du| du_by_label[du.label] = du.id }
              s[:quantities].map do |quantity|
                if du_by_label.keys.include?(quantity[:label])
                  value = Float(quantity[:quantity]) rescue nil
                  quantities[du_by_label[quantity[:label]]] = value if value
                end
              end

              Visit.without_callback(:update, :before, :update_outdated) do
                # Do not flag route as outdated just for quantities change, route quantities are computed after loop
                stops_map[s[:order_id]].visit.update_attributes(quantities: quantities)
              end
              routes_quantities_changed << stops_map[s[:order_id]].route
            end

            stops_map[s[:order_id]].assign_attributes(status: s[:status], eta: s[:eta])
          end
        }

        routes_quantities_changed.map do |route|
          route.compute_quantities
        end

        stops_status
      end
    end
  end

  def to_s
    "#{name}=>" + routes.collect(&:to_s).join(' ')
  end

  def to_geojson(include_stores = true, respect_hidden = true, include_linestrings = :polyline, with_quantities = false)
    Route.routes_to_geojson(routes, include_stores, respect_hidden, include_linestrings, with_quantities)
  end

  def save_import
    if valid? && !customer.too_many_plannings? && Planning.import([self], recursive: true, validate: false)
      # Import does not save has_and_belongs_to_many
      # So save it manually
      # https://github.com/zdennis/activerecord-import/pull/380
      t, z = self.tags, self.zonings
      self.reload
      self.tags, self.zonings = t, z
      # ActiveRecordImport doesn't call callbacks
      self.routes.each { |route| route.complete_geojson }
      save
    end
  end

  def save_import!
    validate!
    raise(Exceptions::OverMaxLimitError.new(I18n.t('activerecord.errors.models.customer.attributes.plannings.over_max_limit'))) if customer.too_many_plannings?
    Planning.import([self], recursive: true, validate: false)

    # Import does not save has_and_belongs_to_many
    # So save it manually
    # https://github.com/zdennis/activerecord-import/pull/380
    t, z = self.tags, self.zonings
    self.reload
    self.tags, self.zonings = t, z
    # ActiveRecordImport doesn't call callbacks
    self.routes.each { |route| route.complete_geojson }
    save!
  end

  def averages(metric)
    routes_distance = 0
    converter = (metric == 'km') ? 3.6 : 2.237
    result = {
      routes_visits_duration: 0,
      routes_speed_average: 0,
      routes_drive_time: 0,
      routes_wait_time: 0,
      vehicles_used: 0,
      vehicles: 0
    }

    routes.each do |route|
      if route.vehicle_usage && !route.drive_time.nil?
        result[:routes_drive_time] += route.drive_time
        result[:vehicles_used] += 1 if route.drive_time > 0

        result[:routes_visits_duration] += route.visits_duration if route.visits_duration
        result[:routes_wait_time] += route.wait_time if route.wait_time

        routes_distance += route.distance
      end
      result[:vehicles] += 1 if route.vehicle_usage
    end

    if result[:routes_drive_time] != 0
      result[:routes_speed_average] = ((routes_distance / result[:routes_drive_time]) * converter).round
      result[:routes_wait_time] = result[:routes_wait_time] > 0 ? result[:routes_wait_time] : nil
      result[:routes_visits_duration] = result[:routes_visits_duration] > 0 ? result[:routes_visits_duration] : nil
    else
      result = nil
    end

    result
  end

  def all_skills
    routes.map do |r|
      next unless r.vehicle_usage
      [r.vehicle_usage.tags, r.vehicle_usage.vehicle.tags].flatten
    end.flatten.compact
  end

  def skills?
    all_skills.any?
  end

  private

  # To reduce matrix computation with only one route... remove code?
  def amalgamate_stops_same_position(stops, global, vehicle_usages)
    tws_or_quantities = stops.find{ |stop|
      stop.is_a?(StopRest) || stop.open1 || stop.close1 || stop.open2 || stop.close2
    }
    units_with_default = stops.flat_map{ |stop| stop.is_a?(StopVisit) && stop.visit.default_quantities.try(:keys) }.compact
    multiples_vehicles_with_capacities = vehicle_usages.size > 1 || vehicle_usages.any? { |v| v.vehicle.default_capacities.any? { |k, v| units_with_default.include?(k) && v } }
    if tws_or_quantities || multiples_vehicles_with_capacities
      # Can't reduce cause of time windows, quantities or multiple vehicles
      positions_uniq = stops.collect{ |stop|
        tags_label = stop.is_a?(StopVisit) ? (stop.visit.destination.tags | stop.visit.tags).map(&:label) & all_skills.map(&:label) : nil
        [stop.lat, stop.lng, stop.id, stop.open1.try(:to_f), stop.close1.try(:to_f), stop.open2.try(:to_f), stop.close2.try(:to_f), stop.priority, stop.duration, (!global || stop.is_a?(StopRest)) ? stop.route.vehicle_usage_id : nil, stop.is_a?(StopVisit) ? stop.visit.default_quantities : nil, stop.is_a?(StopVisit) ? stop.visit.quantities_operations : nil, tags_label, stop.is_a?(StopRest)]
      }

      yield(positions_uniq)
    else
      # Reduce positions vector size by amalgamate points in same position
      stock = Hash.new { [] }
      i = -1
      stops.each{ |stop|
        stock[[stop.lat, stop.lng]] += [[stop, i += 1]]
      }

      positions_uniq = Hash.new { [] }
      stock.each{ |k, v|
        tags_label = v[0][0].is_a?(StopVisit) ? (v[0][0].visit.destination.tags | v[0][0].visit.tags).map(&:label) & all_skills.map(&:label) : nil
        positions_uniq[v[0][0].id] = k + [v[0][0].id, nil, nil, nil, nil, v[0][0].priority, v.sum{ |vs| vs[0].duration }, !global ? v[0][0].route.vehicle_usage_id : nil, v[0][0].is_a?(StopVisit) ? v[0][0].visit.default_quantities : nil, v[0][0].is_a?(StopVisit) ? v[0][0].visit.quantities_operations : nil, tags_label, v[0][0].is_a?(StopRest)]
      }

      optim_uniq = yield(positions_uniq.collect{ |_k, v| v })

      optim_uniq.collect{ |r|
        r.flat_map{ |s|
          stock[positions_uniq[s][0..1]]
        }.collect{ |pa|
          pa[0].id
        }
      }
    end
  end

  def unnil_positions(positions, tws)
    not_nil_position_index = positions.each_with_index.group_by{ |position, _index| !position[0].nil? && !position[1].nil? }

    if not_nil_position_index.key?(true)
      not_nil_position, not_nil_tws = not_nil_position_index[true].collect{ |position, index| [position, tws[index]] }.transpose
    else
      not_nil_position = []
      not_nil_tws = []
    end
    if not_nil_position_index.key?(false)
      nil_tws = not_nil_position_index[false].collect{ |_position, index| tws[index] }
    else
      nil_tws = []
    end

    yield(not_nil_position, not_nil_tws, nil_tws)
  end

  def prefered_route_and_index(available_routes, stop, options = {})
    options[:active_only] = true if options[:active_only].nil?
    cache_sum_out_of_window = Hash.new{ |h, k| h[k] = k.sum_out_of_window }
    tmp_routes = {}

    by_distance = available_routes.flat_map { |route|
      stops = route.stops.select { |s| (options[:active_only] ? s.active? : true) && s.position? }
      stops.map { |s| [s.position, route, s.index] } +
        [stops.empty? ? [route.vehicle_usage.try(:default_store_start), route, 1] : nil,
        ((stop.route_id != route.id) && route.vehicle_usage.try(:default_store_stop).try(:position?)) ? [route.vehicle_usage.default_store_stop, route, route.stops.size + 1] : nil]
    }.compact.sort_by{ |a|
      a[0] && a[0].position? ? a[0].distance(stop.position) : Float::INFINITY
    }
    # If more than one available_routes take at least one stop from second route
    pos_second_route = by_distance.index{ |s| s[1].id != by_distance[0][1].id } if available_routes.size > 1
    # Take 5% from nearest stops (min: 3, max: 10) and a stop in second route if it exists
    (by_distance[0..[9, [2, by_distance.size / 20].max].min] +
      (pos_second_route ? [by_distance[pos_second_route]] : [])).flat_map{ |dest_route_idx|
      [[dest_route_idx[1], dest_route_idx[2]], [dest_route_idx[1], dest_route_idx[2] + 1]]
    }.uniq.map { |ri|
      ri[0].class.amoeba do
        clone :stops # Only duplicate 10 stops just for compute evaluation
        nullify :planning_id
      end

      tmp_routes[ri[0].id] = ri[0].amoeba_dup if !tmp_routes[ri[0].id]
      r = tmp_routes[ri[0].id]
      if stop.is_a?(StopVisit)
        r.add(stop.visit, ri[1], true)
      else
        r.add_or_update_rest(true)
      end
      r.compute(no_geojson: true, no_quantities: true)

      # Difference of total time + difference of sum of out_of_window time
      ri[2] = ((r.end - r.start) - (ri[0].end && ri[0].start ? ri[0].end - ri[0].start : 0)) + (r.sum_out_of_window - cache_sum_out_of_window[ri[0]])
      # Delta distance
      ri[3] = r.distance - ri[0].distance

      r.remove_visit(stop.visit) if stop.is_a?(StopVisit)

      # Return ri with time and distance added
      ri
    }.select { |ri|
      # Check for max time or distance if any
      route_available = true
      route_available = ri[2].abs < options[:max_time] if options[:max_time] && route_available
      route_available = ri[3].abs < options[:max_distance] if options[:max_distance] && route_available
      route_available
    }.min_by { |ri|
      # Return route with the minimum time
      ri[2]
    }
  end

  def update_routes_changed
    @routes_changed = true
  end

  def routes_changed?
    @routes_changed
  end

  def update_zonings_track(_zoning)
    @zoning_ids_changed = true
  end

  def zoning_ids_changed?
    @zoning_ids_changed
  end

  def update_tags_track(_tag)
    @tag_ids_changed = true
  end

  def tag_ids_changed?
    @tag_ids_changed
  end

  def update_zonings
    self.zoning_outdated = true if @zoning_ids_changed
  end

  def check_max_planning
    !self.customer.too_many_plannings? || raise(Exceptions::OverMaxLimitError.new(I18n.t('activerecord.errors.models.customer.attributes.plannings.over_max_limit')))
  end

  def update_vehicle_usage_set
    if vehicle_usage_set_id_changed? && !vehicle_usage_set_id_was.nil? && !id.nil?
      h = Hash[routes.select(&:vehicle_usage).collect{ |route| [route.vehicle_usage.vehicle, route] }]
      vehicle_usage_set.vehicle_usages.each{ |vehicle_usage|
        if h[vehicle_usage.vehicle] && vehicle_usage.active
          h[vehicle_usage.vehicle].vehicle_usage = vehicle_usage
          h[vehicle_usage.vehicle].save!
        elsif vehicle_usage.active
          vehicle_usage_add vehicle_usage
        elsif h[vehicle_usage.vehicle]
          vehicle_usage_remove h[vehicle_usage.vehicle].vehicle_usage
        end
      }
      compute
    end
  end

  def begin_after_end_date
    if self.begin_date.present? && self.end_date.present? && self.end_date < self.begin_date
      errors.add(:end_date, I18n.t('activerecord.errors.models.planning.attributes.end_date.after'))
    end
  end
end
