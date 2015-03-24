class Task < ActiveRecord::Base
  include ApplicationHelper

  def self.permissions
    { 
      student: [ :get, :put, :get_submission, :make_submission, :delete_own_comment ],
      tutor: [ :get, :put, :get_submission, :make_submission, :delete_other_comment, :delete_own_comment ],
      convenor: [ :get, :get_submission, :make_submission, :delete_other_comment, :delete_own_comment ],
      nil => []
    }
  end

  def role_for(user)
    return project.user_role(user)
  end

  # Model associations
  belongs_to :task_definition       # Foreign key
  belongs_to :project               # Foreign key
  belongs_to :task_status           # Foreign key
  has_many :sub_tasks,      dependent: :destroy
  has_many :comments, class_name: "TaskComment", dependent: :destroy, inverse_of: :task

  after_save :update_project

  def self.for_unit(unit_id)
    Task.joins(:project).where("projects.unit_id = :unit_id", unit_id: unit_id)
  end

  def self.for_user(user)
    Task.joins(project: :unit_role).where("unit_roles.user_id = ?", user.id)
  end

  def self.default
    task_definition             = self.new

    task_definition.name        = "New Task"
    task_definition.description = "Enter a description for this task."
    task_definition.weighting   = 0.0
    task_definition.required    = true
    task_definition.target_date = Date.today

    task_definition
  end

  def upload_requirements
    task_definition.upload_requirements
  end
  
  def processing_pdf
    portfolio_evidence == nil && ready_to_mark?
  end

  def update_project
    project.update_attribute(:progress, project.calculate_progress)
    project.update_attribute(:status, project.calculate_status)
  end

  def overdue?
    # A task cannot be overdue if it is marked complete
    return false if complete?

    # Compare the recommended date with the date given to determine
    # if the task is overdue
    recommended_date = task_definition.target_date
    project.reference_date > recommended_date && weeks_overdue >= 1
  end

  def long_overdue?
    # A task cannot be overdue if it is marked complete
    return false if complete?

    # Compare the recommended date with the date given to determine
    # if the task is overdue
    recommended_date = task_definition.target_date
    project.reference_date > recommended_date && weeks_overdue > 2
  end

  def currently_due?
    # A task is currently due if it is not complete and over/under the due date by less than
    # 7 days
    !complete? && days_overdue.between?(-7, 7)
  end

  def weeks_until_due
    days_until_due / 7
  end

  def days_until_due
    (task_definition.target_date - project.reference_date).to_i / 1.day
  end

  def weeks_overdue
    days_overdue / 7
  end

  def days_since_completion
    (project.reference_date - completion_date.to_datetime).to_i / 1.day
  end

  def weeks_since_completion
    days_since_completion / 7
  end

  def days_overdue
    (project.reference_date - task_definition.target_date).to_i / 1.day
  end

  def due_date
    task_definition.target_date
  end

  def complete?
    status == :complete
  end

  def discuss?
    status == :discuss
  end
  
  def ok_to_submit?
    status != :complete && status != :discuss
  end

  def ready_to_mark?
    status == :ready_to_mark
  end

  def ready_or_complete?
    status == :complete || status == :discuss || status == :ready_to_mark
  end

  def fix_and_resubmit?
    status == :fix_and_resubmit
  end

  def fix_and_include?
    status == :fix_and_include
  end

  def redo?
    status == :redo
  end

  def need_help?
    status == :need_help
  end

  def working_on_it?
    status == :working_on_it
  end

  def status
    task_status.status_key
  end

  def has_pdf
    (not portfolio_evidence.nil?) and File.exists?(portfolio_evidence)
  end

  def trigger_transition(trigger, by_user, bulk=false)
    #
    # Ensure that assessor is allowed to update the task in the indicated way
    #
    role = project.user_role(by_user)
    return nil if role.nil?
    
    #
    # State transitions based upon the trigger
    #

    #
    # Tutor and student can trigger these actions...
    #
    case trigger
      when "ready_to_mark", "rtm"
        submit
      when "not_submitted"
        engage TaskStatus.not_submitted
      when "not_ready_to_mark"
        engage TaskStatus.not_submitted
      when "need_help"
        engage TaskStatus.need_help
      when "working_on_it"
        engage TaskStatus.working_on_it
      else
        #
        # Only tutors can perform these actions
        #
        if role == :tutor
          case trigger
            when "redo"
              assess TaskStatus.redo, by_user
            when "complete"
              assess TaskStatus.complete, by_user
            when "fix_and_resubmit", "fix"
              assess TaskStatus.fix_and_resubmit, by_user
            when "fix_and_include", "fixinc"
              assess TaskStatus.fix_and_include, by_user
            when "discuss", "d"
              assess TaskStatus.discuss, by_user
          end
        end
    end

    if not bulk then project.calc_task_stats(self) end
  end

  def assess(task_status, assessor)
    # Set the task's status to the assessment outcome status
    # and flag it as no longer awaiting signoff
    self.task_status       = task_status
    self.awaiting_signoff  = false

    # Set the completion date of the task if it's been completed
    if ready_or_complete?
      if completion_date.nil?
        self.completion_date = Time.zone.now
      end
    else
      self.completion_date = nil
    end

    # Save the task
    if save!
      # If a task has been completed, that means the project
      # has definitely started
      project.start

      # If the task was given an assessment outcome
      if assessed?
        # Grab the submission for the task if the user made one
        submission = TaskSubmission.where(task_id: id).order(:submission_time).reverse_order.first
        # Prepare the attributes of the submission
        submission_attributes = {task: self, assessment_time: Time.zone.now, assessor: assessor, outcome: task_status.name}

        # Create or update the submission depending on whether one was made
        if submission.nil?
          TaskSubmission.create! submission_attributes
        else
          submission.update_attributes submission_attributes
          submission.save
        end
      end
    end
  end

  def engage(engagement_status)
    return if [ :complete ].include? task_status.status_key

    self.task_status       = engagement_status
    self.awaiting_signoff  = false
    self.completion_date   = nil

    if save!
      project.start
      TaskEngagement.create!(task: self, engagement_time: Time.zone.now, engagement: task_status.name)
    end
  end

  def submit
    return if [ :complete ].include? task_status.status_key

    self.task_status      = TaskStatus.ready_to_mark
    self.awaiting_signoff = true
    self.completion_date  = Time.zone.now

    if save!
      project.start
      submission = TaskSubmission.where(task_id: self.id).order(:submission_time).reverse_order.first

      if submission.nil?
        TaskSubmission.create!(task: self, submission_time: Time.zone.now)
      else
        if !submission.submission_time.nil? && submission.submission_time < 1.hour.since(Time.zone.now)
          submission.submission_time = Time.zone.now
          submission.save!
        else
          TaskSubmission.create!(task: self, submission_time: Time.zone.now)
        end
      end
    end
  end

  def assessed?
    redo? ||
    fix_and_resubmit? ||
    fix_and_include? ||
    complete?
  end

  def weight
    task_definition.weighting.to_f
  end

  def add_comment(user, text)
    text.strip!
    return nil if user.nil? || text.nil? || text.empty?

    lc = comments.last
    return if lc && lc.user == user && lc.comment == text

    comment = TaskComment.create()
    comment.task = self
    comment.user = user
    comment.comment = text
    comment.save!
    comment
  end

  def last_comment_by(user)
    result = comments.where(user: user).last
    
    return '' if result.nil?
    result.comment
  end
end


