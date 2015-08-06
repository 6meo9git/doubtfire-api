require 'csv'
require 'bcrypt'
require 'json'
require 'moss_ruby'

class Unit < ActiveRecord::Base
  include ApplicationHelper
  include FileHelper

  def self.permissions
    { 
      :Student  => [ :get_unit ],
      :Tutor    => [ :get_unit, :get_students, :enrol_student, :get_ready_to_mark_submissions],
      :Convenor => [ :get_unit, :get_students, :enrol_student, :uploadCSV, :downloadCSV, :update, :employ_staff, :add_tutorial, :add_task_def, :get_ready_to_mark_submissions, :change_project_enrolment ],
      :nil      => []
    }
  end

  def role_for(user)
    if convenors.where('unit_roles.user_id=:id', id: user.id).count == 1
      Role.convenor
    elsif tutors.where('unit_roles.user_id=:id', id: user.id).count == 1
      Role.tutor
    elsif students.where('unit_roles.user_id=:id', id: user.id).count == 1
      Role.student
    else
      nil
    end
  end

  validates_presence_of :name, :description, :start_date, :end_date

  # Model associations.
  # When a Unit is destroyed, any TaskDefinitions, Tutorials, and ProjectConvenor instances will also be destroyed.
  has_many :task_definitions, -> { order "target_date ASC, abbreviation ASC" }, dependent: :destroy
  has_many :projects, dependent: :destroy
  has_many :tutorials, dependent: :destroy
  has_many :unit_roles, dependent: :destroy
  has_many :tasks, through: :projects
  has_many :group_sets, dependent: :destroy
  
  has_many :convenors, -> { joins(:role).where("roles.name = :role", role: 'Convenor') }, class_name: 'UnitRole'
  has_many :staff, ->     { joins(:role).where("roles.name = :role_convenor or roles.name = :role_tutor", role_convenor: 'Convenor', role_tutor: 'Tutor') }, class_name: 'UnitRole' 

  scope :current,               ->{ current_for_date(Time.zone.now) }
  scope :current_for_date,      ->(date) { where("start_date <= ? AND end_date >= ?", date, date) }
  scope :not_current,           ->{ not_current_for_date(Time.zone.now) }
  scope :not_current_for_date,  ->(date) { where("start_date > ? OR end_date < ?", date, date) }
  scope :set_active,            ->{ where("active = ?", true) }
  scope :set_inactive,          ->{ where("active = ?", false) }

  def self.for_user_admin(user)
    if user.has_admin_capability?
      Unit.all
    else
      Unit.joins(:unit_roles).where('unit_roles.user_id = :user_id and unit_roles.role_id = :convenor_role', user_id: user.id, convenor_role: Role.convenor.id)
    end
  end

  def self.default
    unit = self.new

    unit.name         = "New Unit"
    unit.description  = "Enter a description for this unit."
    unit.start_date   = Date.today
    unit.end_date     = 13.weeks.from_now

    unit
  end

  #
  # Returns the tutors associated with this Unit
  # - includes convenor
  def tutors
    User.teaching(self)
  end

  def students
    Project.joins(:unit_role).where('unit_roles.role_id = 1 and projects.unit_id=:unit_id', unit_id: id)
  end

  #
  # Last date/time of scan
  #
  def last_plagarism_scan
    if self[:last_plagarism_scan].nil? 
      DateTime.new(2000,1,1)
    else
      self[:last_plagarism_scan]
    end
  end

  #
  # Returns the email of the first convenor or "acain@swin.edu.au" if there are no convenors
  #
  def convenor_email
    convenor = convenors.first
    if convenor
      convenor.user.email
    else
      "acain@swin.edu.au"
    end
  end

  def active_projects
    projects.where('enrolled = true') 
  end

  # Adds a staff member for a role in a unit
  def employ_staff(user, role)
    old_role = unit_roles.where("user_id=:user_id", user_id: user.id).first
    return old_role if not old_role.nil?

    if (role != Role.student) && user.has_tutor_capability?
      new_staff = UnitRole.new
      new_staff.user_id = user.id
      new_staff.unit_id = id
      new_staff.role_id = role.id
      new_staff.save!
      new_staff
    end
  end

  # Adds a user to this project.
  def enrol_student(user, tutorial=nil)
    if tutorial.is_a?(Tutorial)
      tutorial_id = tutorial.id
    else
      tutorial_id = tutorial
    end

    # Validates that a student is not already assigned to the unit
    existing_role = unit_roles.where("user_id=:user_id", user_id: user.id).first
    return existing_role.project unless existing_role.nil?

    # Validates that the tutorial exists for the unit
    if (not tutorial_id.nil?) && tutorials.where("id=:id", id: tutorial_id).count == 0
      return nil
    end

    # Put the user in the appropriate tutorial (ie. create a new unit_role)
    unit_role = UnitRole.create!(
      user_id: user.id,
      #tutorial_id: tutorial_id,
      unit_id: self.id,
      role_id: Role.where(name: 'Student').first.id
    )

    unit_role.tutorial_id = tutorial_id unless tutorial_id.nil?

    unit_role.save!

    project = Project.create!(
      unit_role_id: unit_role.id,
      unit_id: self.id,
      task_stats: "1.0|0.0|0.0|0.0|0.0|0.0|0.0|0.0|0.0|0.0|0.0|0.0|1.0"
    )

    # Create task instances for the project
    task_definitions_for_project = TaskDefinition.where(unit_id: self.id)

    task_definitions_for_project.each do |task_definition|
      Task.create(
        task_definition_id: task_definition.id,
        project_id: project.id,
        task_status_id: 1,
        awaiting_signoff: false
      )
    end

    project
  end

  # Removes a user (and their tasks etc.) from this project
  def remove_user(user_id)
    unit_roles = UnitRole.joins(project: :unit).where(user_id: user_id, projects: {unit_id: self.id})

    unit_roles.each do |unit_role|
      unit_role.destroy
    end
  end

  def change_convenors(convenor_ids)
    convenor_role = Role.convenor

    # Replace the current list of convenors for this project with the new list selected by the user
    unit_convenors        = UnitRole.where(unit_id: self.id, role_id: convenor_role.id)
    removed_convenor_ids  = unit_convenors.map(&:user).map(&:id) - convenor_ids

    # Delete any convenors that have been removed
    UnitRole.where(unit_id: self.id, role_id: convenor_role.id, user_id: removed_convenor_ids).destroy_all

    # Find or create convenors
    convenor_ids.each do |convenor_id|
      new_convenor = UnitRole.find_or_create_by_unit_id_and_user_id_and_role_id(unit_id: self.id, user_id: convenor_id, role_id: convenor_role.id)
      new_convenor.save!
    end
  end

  def tutorial_with_abbr(abbr)
    tutorials.where(abbreviation: abbr).first
  end

  #
  # Imports users into a project from CSV file.
  # Format: unit_code, Student ID,First Name,Surname,email,tutorial
  #
  def import_users_from_csv(file)
    tutorial_cache = {}
    success = []
    errors = []
    ignored = []
    
    CSV.foreach(file) do |row|
      # Make sure we're not looking at the header or an empty line
      next if row[0] =~ /(subject|unit)_code/
      # next if row[5] !~ /^LA\d/

      begin
        unit_code, username  = row[0..1]
        first_name, last_name   = [row[2], row[3]].map{|name| name.titleize unless name.nil? }
        email, tutorial_code    = row[4..5]

        if unit_code != code
          ignored << { row: row, message: "Invalid unit code. #{unit_code} does not match #{code}" }
          next
        end

        if ! email =~ /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\z/i
          ignored << { row: row, message: "Invalid email address (#{email})" }
          next
        end

        username = username.downcase

        project_participant = User.find_or_create_by(username: username) {|new_user|
          new_user.first_name         = first_name
          new_user.last_name          = last_name
          new_user.nickname           = first_name
          new_user.role_id            = Role.student_id
          new_user.email              = email
          new_user.encrypted_password = BCrypt::Password.create("password")
        }

        if not project_participant.persisted?
          project_participant.password = "password"
          project_participant.save
        end

        #
        # Only import if a valid user - or if save worked
        #
        if project_participant.persisted?
          user_not_in_project = UnitRole.joins(project: :unit).where(
            user_id: project_participant.id,
            projects: {unit_id: id}
          ).count == 0

          tutorial = tutorial_cache[tutorial_code] || tutorial_with_abbr(tutorial_code)
          tutorial_cache[tutorial_code] ||= tutorial

          # Add the user to the project (if not already in there)
          if user_not_in_project
            if not tutorial.nil?
              enrol_student(project_participant, tutorial)
              success << { row: row, message: "Enrolled student with tutorial." }
            else
              enrol_student(project_participant)
              success << { row: row, message: "Enrolled student without tutorial." }
            end
          else
            # update tutorial
            unit_role = UnitRole.joins(project: :unit).where(
              user_id: project_participant.id,
              projects: {unit_id: id}
            ).first
            unit_role = UnitRole.find(unit_role.id)

            changes = ""          

            if unit_role.tutorial != tutorial
              unit_role.tutorial = tutorial
              unit_role.save
              changes << "Changed tutorial. "
            end

            if not unit_role.project.enrolled
              user_project = unit_role.project
              user_project.enrolled = true
              user_project.save
              changes << "Changed enrolment."
            end

            if changes.length == 0
              ignored << { row: row, message: "No change." }
            else
              success << { row: row, message: changes }
            end
          end
        else
          errors << { row: row, message: "Student record is invalid." }
        end
      rescue Exception => e
        errors << { row: row, message: "Unexpected error: #{e.message}" }
      end
    end
    
    {
      success: success,
      ignored: ignored,
      errors:  errors
    }
  end

  # Use the values in the CSV to set the enrolment of these
  # students to false for this unit.
  # CSV should contain just the usernames to withdraw
  def unenrol_users_from_csv(file)
    # puts 'starting withdraw'
    success = []
    errors = []
    ignored = []
    
    CSV.parse(file, {:headers => true, :header_converters => [:downcase]}).each do |row|
      # Make sure we're not looking at the header or an empty line
      next if row[0] =~ /(username)|(((unit)|(subject))_code)/
      # next if row[5] !~ /^LA\d/

      begin
        unit_code = row['unit_code']
        username  = row['username'].downcase unless row['username'].nil?

        if unit_code != code
          ignored << { row: row, message: "Invalid unit code. #{unit_code} does not match #{code}" }
          next
        end

        # puts username

        project_participant = User.where(username: username)

        if not project_participant
          errors << { row:row, message: "User #{username} not found" }
          next
        end
        if not project_participant.count == 1
          errors << { row:row, message: "User #{username} not found" }
          next
        end

        project_participant = project_participant.first

        user_project = UnitRole.joins(project: :unit).where(
            user_id: project_participant.id,
            projects: {unit_id: id}
          )

        if not user_project
          ignored << { row:row, message: "User #{username} not enrolled in unit" }
          next
        end

        if not user_project.count == 1
          ignored << { row:row, message: "User #{username} not enrolled in unit" }
          next
        end

        user_project = user_project.first.project

        if user_project.enrolled
          user_project.enrolled = false
          user_project.save
          success << { row:row, message: "User #{username} withdrawn from unit" }
        else
          ignored << { row:row, message: "User #{username} not enrolled in unit" }
        end
      rescue Exception => e
        errors << { row: row, message: "Unexpected error: #{e.message}" }
      end
    end

    {
      success: success,
      ignored: ignored,
      errors:  errors
    }
  end 

  def export_users_to_csv
    CSV.generate do |row|
      row << ["unit_code", "username", "first_name", "last_name", "email", "tutorial"]
      students.each do |project|
        row << [project.unit.code, project.student.username,  project.student.first_name, project.student.last_name, project.student.email, project.tutorial_abbr]
      end
    end
  end

  def import_groups_from_csv(group_set, file)
    added = []
    errors = []

    CSV.parse(file, {:headers => true, :header_converters => [:downcase]}).each do |row|
      next if row[0] =~ /^(group_name)|(name)/ # Skip header

      grp = group_set.groups.find_or_create_by(name: row['group_name'])

      user = User.where(username: row['username']).first
      project = students.where('unit_roles.user_id = :id', id: user.id).first

      if project.nil?
        errors << { group: "#{row['group_name']}", user: "#{row['username']}", reason: "Student not found" }
        next
      end

      if grp.new_record?
        tutorial = tutorial_with_abbr(row['tutorial'])
        if tutorial.nil?
          errors << { group: "#{row['group_name']}", user: "#{row['username']}", reason: "Tutorial not found" }
          next
        end

        grp.tutorial = tutorial
        grp.save
      end

      begin
        grp.add_member(project)
      rescue Exception => e
        errors << { group: "#{row['group_name']}", user: "#{row['username']}", reason: e.message }
        next
      end
      added << { group: "#{row['group_name']}", user: "#{row['username']}" }
    end

    {
      errors: errors,
      added: added
    }
  end

  def export_groups_to_csv(group_set)
    CSV.generate do |row|
      row << ["group_name", "username", "tutorial"]
      group_set.groups.each do |grp|
        grp.projects.each do |project|
          row << [grp.name, project.student.username,  grp.tutorial.abbreviation]
        end
      end
    end
  end

  # def import_tutorials_from_csv(file)
  #   CSV.foreach(file) do |row|
  #     next if row[0] =~ /Subject Code/ # Skip header

  #     class_type, abbrev, day, time, location, tutor_username = row[2..-1]
  #     next if class_type !~ /Lab/

  #     add_tutorial(day, time, location, tutor_username, abbrev)
  #   end
  # end
  
  def add_tutorial(day, time, location, tutor, abbrev)
    tutor_role = unit_roles.where("user_id=:user_id", user_id: tutor.id).first
    if tutor_role.nil? || tutor_role.role == Role.student
      return nil
    end
    
    Tutorial.find_or_create_by( { unit_id: id, abbreviation: abbrev } ) do |tutorial|
      tutorial.meeting_day      = day
      tutorial.meeting_time     = time
      tutorial.meeting_location = location
      tutorial.unit_role_id     = tutor_role.id
    end
  end

  def add_new_task_def(task_def, project_cache=nil)
    project_cache = Project.where(unit_id: id) if project_cache.nil?
    project_cache.each do |project|
      Task.create(
        task_definition_id: task_def.id,
        project_id:         project.id,
        task_status_id:     1,
        awaiting_signoff:   false,
        completion_date:    nil
      )
    end
  end

  def import_tasks_from_csv(file)
    added_tasks = []
    updated_tasks = []
    failed_tasks = []
    project_cache = Project.where(unit_id: id)

    CSV.parse(file, {:headers => true, :header_converters => [:downcase]}).each do |row|
      next if row[0] =~ /^(Task Name)|(name)/ # Skip header

      task_definition, new_task = TaskDefinition.task_def_for_csv_row(self, row)

      next if task_definition.nil?

      if task_definition.persisted?
        if new_task
          add_new_task_def task_definition, project_cache
          added_tasks.push(task_definition)
        else
          updated_tasks.push(task_definition)
        end
      else
        failed_tasks.push(task_definition)
      end
    end

    {
      added:    added_tasks,
      updated:  updated_tasks,
      failed:   failed_tasks
    }
  end

  def task_definitions_csv
    TaskDefinition.to_csv(task_definitions)
  end

  def task_completion_csv(options={})
    CSV.generate(options) do |csv|
      csv << [
        'Student ID',
        'Student Name',
        'Target Grade',
        'Email',
        'Portfolio',
        'Tutorial',
      ] + task_definitions.map{|task_definition| task_definition.abbreviation }
      active_projects.each do |project|
        csv << project.task_completion_csv
      end
    end
  end

  def status_distribution
    Project.status_distribution(projects)
  end

  #
  # Create a temp zip file with all student portfolios
  #
  def get_portfolio_zip(current_user)
    # Get a temp file path
    filename = FileHelper.sanitized_filename("portfolios-#{self.code}-#{current_user.username}.zip")
    result = Tempfile.new(filename)
    # Create a new zip
    Zip::File.open(result.path, Zip::File::CREATE) do | zip |
      active_projects.each do | project |
        # Skip if no portfolio at this time...
        next if not project.portfolio_available
        
        # Add file to zip in grade folder
        src_path = project.portfolio_path
        if project.main_tutor
          dst_path = FileHelper.sanitized_path( "#{project.target_grade_desc}", "#{project.student.username}-portfolio (#{project.main_tutor.name})") + ".pdf"
        else
          dst_path = FileHelper.sanitized_path( "#{project.target_grade_desc}", "#{project.student.username}-portfolio (no tutor)") + ".pdf"
        end

        #copy into zip
        zip.add(dst_path, src_path)
      end #active_projects
    end #zip
    result
  end

  #
  # Get all of the related tasks
  #
  def tasks_for_definition(task_def)
    tasks.where(task_definition_id: task_def.id)
  end

  #
  # Update the student's max_pct_similar for all of their tasks
  #
  def update_student_max_pct_similar()
    projects.each do | p |
      p.max_pct_similar = p.tasks.maximum(:max_pct_similar)
      p.save
    end
  end

  def create_plagiarism_link(t1, t2, match)
    plk1 = PlagiarismMatchLink.where(task_id: t1.id, other_task_id: t2.id).first
    plk2 = PlagiarismMatchLink.where(task_id: t2.id, other_task_id: t1.id).first

    # Delete old links between tasks
    plk1.destroy unless plk1.nil? ## will delete its pair
    plk2.destroy unless plk2.nil?

    plk1 = PlagiarismMatchLink.create do | pml |
      pml.task = t1
      pml.other_task = t2
      pml.plagiarism_report_url = match[0][:url]

      pml.pct = match[0][:pct]
    end

    plk2 = PlagiarismMatchLink.create do | pml |
      pml.task = t2
      pml.other_task = t1
      pml.plagiarism_report_url = match[1][:url]

      pml.pct = match[1][:pct]
    end

    FileHelper.save_plagiarism_html(plk1, match[0][:html])
    FileHelper.save_plagiarism_html(plk2, match[1][:html])
  end

  def update_plagiarism_stats()
    moss = MossRuby.new(Doubtfire::Application.config.moss_key)

    task_definitions.where(plagiarism_updated: true).each do |td|
      td.plagiarism_updated = false
      td.save

      #delete old plagiarism links
      puts "Deleting old links for task definition #{td.id}"
      PlagiarismMatchLink.joins(:task).where("tasks.task_definition_id" => td.id).each do | plnk |
        begin
          PlagiarismMatchLink.find(plnk.id).destroy!
        rescue
        end
      end

      # Reset the tasks % similar
      puts "Clearing old task percent similar"
      tasks_for_definition(td).where("tasks.max_pct_similar > 0").each do |t|
        t.max_pct_similar = 0
        t.save
      end

      # Get results
      url = td.plagiarism_report_url
      puts "Processing MOSS results #{url}"
      
      warn_pct = td.plagiarism_warn_pct
      warn_pct = 50 if warn_pct.nil?

      results = moss.extract_results( url, warn_pct, lambda { |line| puts line } )

      # Use results
      results.each do |match|
        next if match[0][:pct] < warn_pct && match[1][:pct] < warn_pct

        task_id_1 = /.*\/(\d+)\/$/.match(match[0][:filename])[1]
        task_id_2 = /.*\/(\d+)\/$/.match(match[1][:filename])[1]

        t1 = Task.find(task_id_1)
        t2 = Task.find(task_id_2)

        if t1.nil? || t2.nil?
          puts "Could not find tasks #{task_id_1} or #{task_id_2}"
          next
        end

        if td.group_set # its a group task
          g1_tasks = t1.group_submission.tasks
          g2_tasks = t2.group_submission.tasks

          g1_tasks.each do | gt1 |
            g2_tasks.each do | gt2 |
              create_plagiarism_link(gt1, gt2, match)
            end
          end

        else # just link the individuals...
          create_plagiarism_link(t1, t2, match)
        end
      end # end of each result
    end # for each task definition where it needs to be updated
    update_student_max_pct_similar()

    self
  end

  #
  # Extract all done files related to a task definition matching a pattern into a given directory.
  # Returns an array of files
  #
  def add_done_files_for_plagiarism_check_of(td, tmp_path, force, to_check)
    tasks = tasks_for_definition(td)
    tasks_with_files = tasks.select { |t| t.has_pdf }
    
    if td.group_set
      # group task so only select one member of each group
      seen_groups = []

      tasks_with_files = tasks_with_files.select do |t| 
        if t.group.nil?
          result = false
        else
          result = ! seen_groups.include?(t.group)
          if result
            seen_groups << t.group
          end
        end
        result
      end
    end

    # check number of files, and they are new
    if tasks_with_files.count > 1 && (tasks.where("tasks.file_uploaded_at > ?", last_plagarism_scan ).select { |t| t.has_pdf }.count > 0 || force )
      td.plagiarism_checks.each do |check|
        next if check["type"].nil?

        type_data = check["type"].split(" ")
        next if type_data.nil? or type_data.length != 2 or type_data[0] != "moss"

        # extract files matching each pattern
        # -- each pattern
        check["pattern"].split("|").each do |pattern|
          # puts "\tadding #{pattern}"
          tasks_with_files.each do |t|
            FileHelper.extract_file_from_done(t, tmp_path, pattern, lambda { | task, to_path, name |  File.join("#{to_path}", "#{t.student.username}", "#{name}") } )
          end
          MossRuby.add_file(to_check, "**/#{pattern}")
        end
      end
    end

    self
  end

  #
  # Pass tasks on to plagarism detection software and setup links between students
  #
  def check_plagiarism(force = false)
    # Get each task...
    return if not active

    # need pwd to restore after cding into submission folder (so the files do not have full path)
    pwd = FileUtils.pwd

    begin
      puts "\nChecking #{name}"
      task_definitions.each do |td|
        next if td.plagiarism_checks.length == 0
        # Is there anything to check?

        puts "- Checking plagiarism for #{td.name}"
        tasks = tasks_for_definition(td)
        tasks_with_files = tasks.select { |t| t.has_pdf }
        if tasks_with_files.count > 1 && (tasks.where("tasks.file_uploaded_at > ?", last_plagarism_scan ).select { |t| t.has_pdf }.count > 0 || force )
          # There are new tasks, check these

          puts "Contacting moss for new checks"
          td.plagiarism_checks.each do |check|
            next if check["type"].nil?

            type_data = check["type"].split(" ")
            next if type_data.nil? or type_data.length != 2 or type_data[0] != "moss"

            # Create the MossRuby object
            moss = MossRuby.new(Doubtfire::Application.config.moss_key)

            # Set options  -- the options will already have these default values
            moss.options[:max_matches] = 7
            moss.options[:directory_submission] = true
            moss.options[:show_num_matches] = 500
            moss.options[:experimental_server] = false
            moss.options[:comment] = ""
            moss.options[:language] = type_data[1]

            tmp_path = File.join( Dir.tmpdir, 'doubtfire', "check-#{id}-#{td.id}" )

            # Create a file hash, with the files to be processed
            to_check = MossRuby.empty_file_hash
            add_done_files_for_plagiarism_check_of(td, tmp_path, force, to_check)

            FileUtils.chdir(tmp_path)

            # Get server to process files
            puts "Sending to MOSS..."
            url = moss.check(to_check, lambda { |line| puts line })

            FileUtils.chdir(pwd)
            FileUtils.rm_rf tmp_path

            td.plagiarism_report_url = url
            td.plagiarism_updated = true
            td.save
          end
        end
      end
      update_student_max_pct_similar()
      self.last_plagarism_scan = DateTime.now
      self.save!
    ensure
      if FileUtils.pwd() != pwd
        FileUtils.chdir(pwd)
      end
    end

    self
  end

  def import_task_files_from_zip zip_file
    task_path = FileHelper.task_file_dir_for_unit self, create=true

    result = {
      :added_files => [],
      :ignored_files => []
    }

    Zip::File.open(zip_file) do |zip|
      zip.each do |file|
        file_name = File.basename(file.name)
        if not task_definitions.where(abbreviation: File.basename(file_name, ".*"))
          result[:ignored_files] << { name: file.name }
        elsif File.extname(file.name) == ".pdf"
          file.extract ("#{task_path}#{FileHelper.sanitized_filename(file_name)}") {true}
          result[:added_files] << { name: file.name }
        elsif File.extname(file.name) == ".zip"
          file.extract ("#{task_path}#{FileHelper.sanitized_filename(file_name)}") {true}
          result[:added_files] << { name: file.name }
        else
          result[:ignored_files] << { name: file.name }
        end
      end
    end

    result
  end

  def path_to_task_resources(task_def)
    task_path = FileHelper.task_file_dir_for_unit self, create=false
    "#{task_path}#{FileHelper.sanitized_filename(task_def.abbreviation)}.zip"
  end

  def path_to_task_pdf(task_def)
    task_path = FileHelper.task_file_dir_for_unit self, create=false
    "#{task_path}#{FileHelper.sanitized_filename(task_def.abbreviation)}.pdf"
  end
end
