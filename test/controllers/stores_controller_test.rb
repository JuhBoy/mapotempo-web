require 'test_helper'

class StoresControllerTest < ActionController::TestCase
  set_fixture_class delayed_jobs: Delayed::Backend::ActiveRecord::Job

  setup do
    @request.env['reseller'] = resellers(:reseller_one)
    @store = stores(:store_one)
    sign_in users(:user_one)
  end

  test 'user can only view stores from its customer' do
    ability = Ability.new(users(:user_one))
    assert ability.can? :manage, @store
    ability = Ability.new(users(:user_three))
    assert ability.cannot? :manage, @store

    get :edit, id: stores(:store_two)
    assert_response :redirect
  end

  test 'should get index' do
    get :index
    assert_response :success
    assert_not_nil assigns(:stores)
    assert_valid response
  end

  test 'should get one' do
    get :show, id: @store, format: :json
    assert_response :success
    assert_valid response
  end

  test 'should get new' do
    get :new
    assert_response :success
    assert_valid response
  end

  test 'should create store' do
    assert_difference('Store.count') do
      post :create, store: { city: @store.city, lat: @store.lat, lng: @store.lng, name: @store.name, postalcode: @store.postalcode, street: @store.street, state: @store.state }
    end

    assert_redirected_to edit_store_path(assigns(:store))
  end

  test 'should not create store' do
    assert_difference('Store.count', 0) do
      post :create, store: { name: '' }
    end

    assert_template :new
    store = assigns(:store)
    assert store.errors.any?
    assert_valid response
  end

  test 'should get edit' do
    get :edit, id: @store
    assert_response :success
    assert_valid response
  end

  test 'should update store' do
    patch :update, id: @store, store: { city: @store.city, lat: @store.lat, lng: @store.lng, name: @store.name, postalcode: @store.postalcode, street: @store.street, state: @store.state }
    assert_redirected_to edit_store_path(assigns(:store))
  end

  test 'should update store with geocode error' do
    Mapotempo::Application.config.geocode_geocoder.class.stub_any_instance(:code, lambda{ |*a| raise GeocodeError.new }) do
      patch :update, id: @store, store: { city: 'Nantes', lat: nil, lng: nil }
      assert_redirected_to edit_store_path(assigns(:store))
      assert_not_nil flash[:warning]
    end
  end

  test 'should not update store' do
    patch :update, id: @store, store: { name: '' }

    assert_template :edit
    store = assigns(:store)
    assert store.errors.any?
    assert_valid response
  end

  test 'should destroy store' do
    assert_difference('Store.count', -1) do
      delete :destroy, id: @store
    end

    assert_redirected_to stores_path
  end

  test 'should show import template' do
    [:csv, :excel].each{ |format|
      get :import_template, format: format
      assert_response :success
    }
  end

  test 'should import' do
    get :import
    assert_response :success
    assert_valid response
  end

  test 'should upload' do
    file = ActionDispatch::Http::UploadedFile.new({
      tempfile: File.new(Rails.root.join('test/fixtures/files/import_stores_one.csv')),
    })
    file.original_filename = 'import_stores_one.csv'

    stores_count = @store.customer.stores.count
    plannings_count = @store.customer.plannings.select{ |planning| planning.tags == [tags(:tag_one)] }.count
    import_count = 1
    rest_count = 1

    assert_difference('Store.count') do
      post :upload_csv, import_csv: { replace: false, file: file }
    end

    assert_redirected_to stores_path
  end

  test 'should not upload' do
    file = ActionDispatch::Http::UploadedFile.new({
      tempfile: File.new(Rails.root.join('test/fixtures/files/import_invalid.csv')),
    })
    file.original_filename = 'import_invalid.csv'

    assert_difference('Store.count', 0) do
      post :upload_csv, import_csv: { replace: false, file: file }
    end

    assert_template :import
    assert_valid response
  end

  test 'should display application layout on devise scope' do
    get :edit, id: @store
    assert_template layout: 'application'
  end
end
