require 'test_helper'

class ApiWeb::V01::StoresControllerTest < ActionController::TestCase
  set_fixture_class delayed_jobs: Delayed::Backend::ActiveRecord::Job

  setup do
    @request.env['reseller'] = resellers(:reseller_one)
    @store = stores(:store_one)
    sign_in users(:user_one)
  end

  test 'user can only view stores from its customer' do
    ability = Ability.new(users(:user_one))
    assert ability.can? :manage, stores(:store_one)
    ability = Ability.new(users(:user_three))
    assert ability.cannot? :manage, stores(:store_one)
    sign_in users(:user_three)
    get :index, ids: stores(:store_one).id
    assert_equal 0, assigns(:stores).count
  end

  test 'should sign in with api_key' do
    sign_out users(:user_one)
    get :index, api_key: 'testkey1'
    assert_response :success
    assert_not_nil assigns(:customer)
  end

  test 'should get index' do
    get :index
    assert_response :success
    assert_nil assigns(:stores)
    assert_valid response
  end

  test 'should get index with ref' do
    get :index, 'ids' => 'ref:b'
    assert_response :success
    assert_not_nil assigns(:stores)
    assert_valid response
  end

  test 'should get edit position' do
    get :edit_position, id: @store
    assert_response :success
    assert_valid response
  end

  test 'should update position' do
    patch :update_position, id: @store, store: { lat: 6, lng: 6 }
    assert_redirected_to api_web_v01_edit_position_store_path(assigns(:store))
  end
end
