# Copyright © Mapotempo, 2013-2016
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
class Tag < ApplicationRecord
  ICON_SIZE = %w(small medium large).freeze
  COLOR_DEFAULT = '#000000'.freeze
  ICON_DEFAULT = 'fa-circle'.freeze
  ICON_SIZE_DEFAULT = 'medium'.freeze

  default_scope { order(:label) }

  belongs_to :customer
  has_and_belongs_to_many :visits
  has_and_belongs_to_many :plannings

  nilify_blanks
  auto_strip_attributes :label

  include RefSanitizer

  validates :label, presence: true
  validates :ref, uniqueness: { scope: :customer_id, case_sensitive: true }, allow_nil: true, allow_blank: true
  validates_format_of :color, with: /\A(|\#[A-Fa-f0-9]{6})\Z/, allow_nil: true

  validates_inclusion_of :icon, in: FontAwesome::ICONS_TABLE, allow_blank: true, message: ->(*_) { I18n.t('activerecord.errors.models.tag.icon_unknown') }
  validates :icon_size, inclusion: { in: Tag::ICON_SIZE, allow_blank: true, message: ->(*_) { I18n.t('activerecord.errors.models.tag.icon_size_invalid') } }

  amoeba do
    exclude_association :visits
    exclude_association :plannings
  end

  def default_color
    color || COLOR_DEFAULT
  end

  def default_icon
    icon || ICON_DEFAULT
  end

  def default_icon_size
    icon_size || ICON_SIZE_DEFAULT
  end
end
