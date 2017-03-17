# Copyright © Mapotempo, 2014-2015
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
class V01::Entities::VehicleWithoutVehicleUsage < Grape::Entity
  def self.entity_name
    'V01_VehicleWithoutVehicleUsage'
  end

  expose(:id, documentation: { type: Integer })
  expose(:contact_email, documentation: { type: String })
  expose(:ref, documentation: { type: String })
  expose(:name, documentation: { type: String })
  expose(:emission, documentation: { type: Float })
  expose(:consumption, documentation: { type: Integer })
  expose(:capacity, documentation: { type: Integer, desc: 'Deprecated, use capacities instead.' }) { |m|
    if m.capacities && m.customer.deliverable_units.size == 1
      capacities = m.capacities.values
      capacities[0] if capacities.size == 1
    end
  }
  expose(:capacity_unit, documentation: { type: String, desc: 'Deprecated, use capacities and deliverable_unit entity instead.' }) { |m|
    if m.capacities && m.customer.deliverable_units.size == 1
      deliverable_unit_ids = m.capacities.keys
      m.customer.deliverable_units[0].label if deliverable_unit_ids.size == 1
    end
  }
  expose(:capacities, using: V01::Entities::DeliverableUnitQuantity, documentation: { type: V01::Entities::DeliverableUnitQuantity, is_array: true, param_type: 'form' }) { |m|
    m.capacities ? m.capacities.to_a.collect{ |a| {deliverable_unit_id: a[0], quantity: a[1]} } : []
  }
  expose(:color, documentation: { type: String, desc: 'Color code with #. For instance: #FF0000' })
  expose(:fuel_type, documentation: { type: String })
  expose(:router_id, documentation: { type: Integer })
  expose(:router_dimension, documentation: { type: String, values: ::Router::DIMENSION.keys })
  expose(:router_options, using: V01::Entities::RouterOptions, documentation: { type: V01::Entities::RouterOptions })
  expose(:speed_multiplicator, documentation: { type: Float })

  # Devices
  # add auth for : orange_id, teksat_id, tomtom_id
  expose(:devices, documentation: {type: Hash})
end

class V01::Entities::Vehicle < V01::Entities::VehicleWithoutVehicleUsage
  def self.entity_name
    'V01_Vehicle'
  end

  expose(:vehicle_usages, using: V01::Entities::VehicleUsage, documentation: { type: V01::Entities::VehicleUsage, is_array: true })
end
