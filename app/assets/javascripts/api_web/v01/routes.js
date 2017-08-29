// Copyright © Mapotempo, 2015-2017
//
// This file is part of Mapotempo.
//
// Mapotempo is free software. You can redistribute it and/or
// modify since you respect the terms of the GNU Affero General
// Public License as published by the Free Software Foundation,
// either version 3 of the License, or (at your option) any later version.
//
// Mapotempo is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
// or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with Mapotempo. If not, see:
// <http://www.gnu.org/licenses/agpl.html>
//
'use strict';

var api_web_v01_routes_index = function(params) {
  'use strict';

  var progressBar = Turbolinks.enableProgressBar();
  progressBar && progressBar.advanceTo(25);

  var prefered_unit = (!params.prefered_unit ? 'km' : params.prefered_unit),
    planning_id = params.planning_id,
    route_ids = params.route_ids;

  var map = mapInitialize(params);
  L.control.attribution({
    prefix: false
  }).addTo(map);
  L.control.scale({
    imperial: false
  }).addTo(map);

  var routesLayer = new RoutesLayer(planning_id, {
    unit: prefered_unit,
    colorsByRoute: params.colors_by_route,
    appBaseUrl: '/api-web/0.1/',
    popupOptions: {
      isoline: false
    },
    disableClusters: params.disable_clusters
  }).addTo(map);

  var caption = L.DomUtil.get('routes-caption');
  if (caption) {
    caption.classList.add('leaflet-bar');
    var control_caption = L.Control.extend({
      options: {
        position: 'bottomright'
      },
      onAdd: function(map) {
        var container = caption;
        L.DomEvent.disableClickPropagation(container);
        return container;
      }
    });
    map.addControl(new control_caption());
  }

  var fitBounds = !window.location.hash;
  // FIXME when turbolinks get updated
  // Must be placed after caption, otherwise hash is override
  if (!params.disable_clusters) {
    if (navigator.userAgent.indexOf('Edge') === -1) {
      map.addHash();
      var removeHash = function() {
        map.removeHash();
        $(document).off('page:before-change', removeHash);
      };
      $(document).on('page:before-change', removeHash);
    }
  }

  routesLayer.showRoutesWithStore(route_ids, null, function() {
    if (fitBounds) {
      progressBar && progressBar.done();
      var bounds = routesLayer.getBounds();
      if (bounds && bounds.isValid()) {
        map.invalidateSize();
        map.fitBounds(bounds, {
          maxZoom: 15,
          animate: false,
          padding: [20, 20]
        });
      }
    }
  });

  progressBar && progressBar.advanceTo(50);
};

var api_web_v01_routes_print = function(params) {
  'use strict';

  $('.btn-print').click(function() {
    window.print();
  });
};

Paloma.controller('ApiWeb/V01/Routes', {
  index: function() {
    api_web_v01_routes_index(this.params);
  },
  print: function() {
    api_web_v01_routes_print(this.params);
  }
});
