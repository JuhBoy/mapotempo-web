# Copyright © Mapotempo, 2017
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
class V01::Devices::SuiviDeFlotte < Grape::API
  namespace :devices do
    namespace :suivi_de_flotte do
      helpers do
        def service
          SuiviDeFlotteService.new customer: @customer
        end
      end

      before do
        @customer = current_customer(params[:customer_id])
      end

      desc 'List Devices',
        detail: 'List Devices',
        nickname: 'deviceTomtomList'
      get '/devices' do
        present service.list_devices, with: V01::Entities::DeviceItem
      end
    end
  end
end
