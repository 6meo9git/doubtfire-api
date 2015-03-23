require 'grape'
require 'unit_serializer'

module Api
  class Units < Grape::API
    helpers AuthHelpers
    helpers AuthorisationHelpers

    before do
      authenticated?

      if params[:unit]
        for key in [ :start_date, :end_date ] do
          if params[:unit][key].present?
            date_val  = DateTime.parse(params[:unit][key])
            params[:unit][key]  = date_val
          end
        end
      end
    end

    desc "Get units related to the current user for admin purposes"
    params do
      optional :include_in_active, type: Boolean, desc: 'Include units that are not active'
    end
    get '/units' do
      if not authorise? current_user, User, :convene_units
        error!({"error" => "Unable to list units" }, 403)
      end

      # gets only the units the current user can "see"
      units = Unit.for_user_admin current_user

      if not params[:include_in_active]
        units = units.where("active = true")
      end

      ActiveModel::ArraySerializer.new(units, each_serializer: ShallowUnitSerializer)
    end

    desc "Get a unit's details"
    get '/units/:id' do
      unit = Unit.find(params[:id])
      if not ((authorise? current_user, unit, :get_unit) || (authorise? current_user, User, :admin_units))
        error!({"error" => "Couldn't find Unit with id=#{params[:id]}" }, 403)
      end
      #
      # Unit uses user from thread to limit exposure
      #
      Thread.current[:user] = current_user
      unit
    end


    desc "Update unit"
    params do
      requires :id, type: Integer, desc: 'The unit id to update'
      group :unit do
        optional :name
        optional :code
        optional :description
        optional :start_date
        optional :end_date
        optional :active
      end
    end
    put '/units/:id' do 
      unit= Unit.find(params[:id])
      if not authorise? current_user, unit, :update
        error!({"error" => "Not authorised to update a unit" }, 403)
      end
      unit_parameters = ActionController::Parameters.new(params)
      .require(:unit)
      .permit(:name,
              :code,
              :description,
              :start_date, 
              :end_date,
              :active
             )

      unit.update!(unit_parameters)
      unit_parameters
    end 


    desc "Create unit"
    params do
      group :unit do
        requires :name
        requires :code
        requires :description
        requires :start_date
        requires :end_date
      end
    end
    post '/units' do
      if not authorise? current_user, User, :create_unit
        error!({"error" => "Not authorised to create a unit" }, 403)
      end
      
      unit_parameters = ActionController::Parameters.new(params)
                                          .require(:unit)
                                          .permit(
                                            :name,
                                            :code,
                                            :description,
                                            :start_date,
                                            :end_date
                                          )
      unit = Unit.create!(unit_parameters)

      # Employ current user as convenor
      unit.employ_staff(current_user, Role.convenor)
      ShallowUnitSerializer.new(unit)
    end
    
    desc "Add a tutorial with the provided details to this unit"
    params do
      #day, time, location, tutor_username, abbrev
      group :tutorial do
        requires :day
        requires :time
        requires :location
        requires :tutor_username
        requires :abbrev
      end
    end
    post '/units/:id/tutorials' do
      unit = Unit.find(params[:id])
      if not authorise? current_user, unit, :add_tutorial
        error!({"error" => "Not authorised to create a tutorial" }, 403)
      end
      
      new_tutorial = params[:tutorial]
      tutor = User.find_by_username(new_tutorial[:tutor_username])
      if tutor.nil?
        error!({"error" => "Couldn't find User with username=#{new_tutorial[:tutor_username]}" }, 403)
      end
      
      result = unit.add_tutorial(new_tutorial[:day], new_tutorial[:time], new_tutorial[:location], tutor, new_tutorial[:abbrev])
      if result.nil?
        error!({"error" => "Tutor username invalid (not a tutor for this unit)" }, 403)
      end
      
      result
    end

    desc "Upload CSV of all the students in a unit"
    params do
      requires :file, type: Rack::Multipart::UploadedFile, :desc => "CSV upload file."
    end
    post '/csv/units/:id' do
      unit = Unit.find(params[:id])
      if not authorise? current_user, unit, :uploadCSV
        error!({"error" => "Not authorised to upload CSV of students to #{unit.code}"}, 403)
      end
      
      # check mime is correct before uploading
      if not params[:file][:type] == "text/csv"
        error!({"error" => "File given is not a CSV file"}, 403)
      end
      
      # Actually import...
      unit.import_users_from_csv(params[:file][:tempfile])
    end

    desc "Upload CSV with the students to un-enrol from the unit"
    params do
      requires :file, type: Rack::Multipart::UploadedFile, :desc => "CSV upload file."
    end
    post '/csv/units/:id/withdraw' do
      unit = Unit.find(params[:id])
      if not authorise? current_user, unit, :uploadCSV
        error!({"error" => "Not authorised to upload CSV of students to #{unit.code}"}, 403)
      end
      
      # check mime is correct before uploading
      if not params[:file][:type] == "text/csv"
        error!({"error" => "File given is not a CSV file"}, 403)
      end
      
      # Actually withdraw...
      unit.unenrol_users_from_csv(params[:file][:tempfile])
    end
    
    desc "Download CSV of all students in this unit"
    get '/csv/units/:id' do
      unit = Unit.find(params[:id])
      if not authorise? current_user, unit, :downloadCSV
        error!({"error" => "Not authorised to download CSV of students enrolled in #{unit.code}"}, 403)
      end
      
      content_type "application/octet-stream"
      header['Content-Disposition'] = "attachment; filename=#{unit.code}-Students.csv "
      env['api.format'] = :binary
      unit.export_users_to_csv
    end

    desc "Download CSV of all student tasks in this unit"
    get '/csv/units/:id/task_completion' do
      unit = Unit.find(params[:id])
      if not authorise? current_user, unit, :downloadCSV
        error!({"error" => "Not authorised to download CSV of student tasks in #{unit.code}"}, 403)
      end
      
      content_type "application/octet-stream"
      header['Content-Disposition'] = "attachment; filename=#{unit.code}-TaskCompletion.csv "
      env['api.format'] = :binary
      unit.task_completion_csv
    end
  end
end
