require 'encoding'

# we need repository permission constants
require File.join(File.dirname(__FILE__),'..', '..', 'lib', 'repo', 'repository')

# Represents a collection of students working together on an assignment in a group
class Grouping < ActiveRecord::Base

  before_create :create_grouping_repository_folder

  before_destroy :revoke_repository_permissions_for_students

  belongs_to :grouping_queue

  has_many :memberships, dependent: :destroy
  has_many :student_memberships, order: 'id'
  has_many :non_rejected_student_memberships,
           class_name: 'StudentMembership',
           conditions: ['memberships.membership_status != ?',
                           StudentMembership::STATUSES[:rejected]]
  has_many :accepted_student_memberships,
           class_name: 'StudentMembership',
           conditions: {
              'memberships.membership_status' => [
                    StudentMembership::STATUSES[:accepted],
                    StudentMembership::STATUSES[:inviter]]}
  has_many :notes, as: :noteable, dependent: :destroy
  has_many :ta_memberships, class_name: 'TaMembership'
  has_many :tas, through: :ta_memberships, source: :user
  has_many :students, through: :student_memberships, source: :user
  has_many :pending_students,
           class_name: 'Student',
           through: :student_memberships,
           conditions: {
            'memberships.membership_status' => StudentMembership::STATUSES[:pending]},
           source: :user

  has_many :submissions
  has_and_belongs_to_many :tags
  #The first submission found that satisfies submission_version_used == true.
  #If there are multiple such submissions, one is chosen randomly.
  has_one :current_submission_used,
          class_name: 'Submission',
          conditions: {submission_version_used: true}
  has_many :grace_period_deductions,
           through: :non_rejected_student_memberships

  has_one :token
  has_one :inviter_membership,
          class_name: 'StudentMembership',
          conditions: {
            membership_status: StudentMembership::STATUSES[:inviter]
          }
  has_one :inviter, source: :user, through: :inviter_membership

  scope :approved_groupings, conditions: {admin_approved: true}

  validates_numericality_of :criteria_coverage_count, greater_than_or_equal_to: 0

  # user association/validation
  belongs_to :assignment, counter_cache: true
  validates_presence_of :assignment_id
  validates_associated :assignment, on: :create, message: 'associated assignment need to be valid'

  belongs_to :group
  validates_presence_of :group_id
  validates_associated :group, message: 'associated group need to be valid'

  validates_inclusion_of :is_collected, in: [true, false]

  # Assigns a random TA from a list of TAs specified by +ta_ids+ to each
  # grouping in a list of groupings specified by +grouping_ids+. The groupings
  # must belong to the given assignment +assignment+.
  def self.randomly_assign_tas(grouping_ids, ta_ids, assignment)
    assign_tas(grouping_ids, ta_ids, assignment) do |grouping_ids, ta_ids|
      # Assign TAs in a round-robin fashion to a list of random groupings.
      grouping_ids.shuffle.zip(ta_ids.cycle)
    end
  end

  # Assigns all TAs in a list of TAs specified by +ta_ids+ to each grouping in
  # a list of groupings specified by +grouping_ids+. The groupings must belong
  # to the given assignment +assignment+.
  def self.assign_all_tas(grouping_ids, ta_ids, assignment)
    assign_tas(grouping_ids, ta_ids, assignment) do |grouping_ids, ta_ids|
      # Get the Cartesian product of grouping IDs and TA IDs.
      grouping_ids.product(ta_ids)
    end
  end

  # Assigns TAs to groupings using a caller-specified block. The block is given
  # a list of grouping IDs and a list of TA IDs and must return a list of
  # grouping-ID-TA-ID pair that represents the TA assignment.
  #
  #   # Assign the TA with ID 3 to the grouping with ID 1 and the TA
  #   # with ID 4 to the grouping with ID 2.
  #   assign_tas([1, 2], [3, 4], a) do |grouping_ids, ta_ids|
  #     grouping_ids.zip(ta_ids)  # => [[1, 3], [2, 4]]
  #   end
  #
  # The groupings must belong to the given assignment +assignment+.
  def self.assign_tas(grouping_ids, ta_ids, assignment)
    grouping_ids, ta_ids = Array(grouping_ids), Array(ta_ids)

    # Only use IDs that identify existing model instances.
    ta_ids = Ta.where(id: ta_ids).pluck(:id)
    grouping_ids = Grouping.where(id: grouping_ids).pluck(:id)

    columns = [:grouping_id, :user_id]
    # Get all existing memberships to avoid violating the unique constraint.
    # TODO replace this with Membership.pluck when migrated to Rails 4.
    existing_values = TaMembership.select(columns)
      .where(grouping_id: grouping_ids, user_id: ta_ids)
      .map { |membership| [membership.grouping_id, membership.user_id] }
    # Delegate the assign function to the caller-specified block and remove
    # values that already exist in the database.
    values = yield(grouping_ids, ta_ids) - existing_values
    # TODO replace TaMembership.import with TaMembership.create when the PG
    # driver supports bulk create, then remove the activerecord-import gem.
    TaMembership.import(columns, values, validate: false)

    update_criteria_coverage_counts(assignment, grouping_ids)
    Criterion.update_assigned_groups_counts(assignment)
  end

  # Unassigns TAs from groupings. +ta_membership_ids+ is a list of TA
  # membership IDs that specifies the unassignment to be done. +grouping_ids+
  # is a list of grouping IDs involved in the unassignment. The memberships
  # and groupings must belong to the given assignment +assignment+.
  def self.unassign_tas(ta_membership_ids, grouping_ids, assignment)
    TaMembership.delete_all(id: ta_membership_ids)

    update_criteria_coverage_counts(assignment, grouping_ids)
    Criterion.update_assigned_groups_counts(assignment)
  end

  # Updates the +criteria_coverage_count+ field of all groupings specified
  # by +grouping_ids+.
  def self.update_criteria_coverage_counts(assignment, grouping_ids = nil)
    # Sanitize the IDs in the input.
    grouping_ids_str = Array(grouping_ids)
      .map { |grouping_id| connection.quote(grouping_id) }
      .join(',')
    # TODO replace this raw SQL with dynamic SET clause with Active Record
    # language when the latter supports subquery in the SET clause.
    connection.execute(<<-UPDATE_SQL)
      UPDATE groupings AS g SET criteria_coverage_count =
        (SELECT count(DISTINCT c.criterion_id) FROM memberships AS m
          INNER JOIN criterion_ta_associations AS c ON m.user_id = c.ta_id
          WHERE m.grouping_id = g.id AND m.type = 'TaMembership'
            AND c.assignment_id = g.assignment_id)
        WHERE assignment_id = #{assignment.id}
          #{"AND id IN (#{grouping_ids_str})" unless grouping_ids_str.empty?}
    UPDATE_SQL
  end

  def accepted_students
    self.accepted_student_memberships.collect do |memb|
      memb.user
    end
  end

  def get_all_students_in_group
    student_user_names = student_memberships.collect {|m| m.user.user_name }
    return I18n.t('assignment.group.empty') if student_user_names.size == 0
	  student_user_names.join(', ')
  end

  def group_name_with_student_user_names
		user_names = get_all_students_in_group
    return group.group_name if user_names == I18n.t('assignment.group.empty')
    group.group_name + ': ' + user_names
  end

  def display_for_note
    assignment.short_identifier + ': ' + group_name_with_student_user_names
  end

  # Query Functions ------------------------------------------------------

  # Returns whether or not a TA is assigned to mark this Grouping
  def has_ta_for_marking?
    ta_memberships.count > 0
  end

  #Returns whether or not the submission_collector is pending to collect this
  #grouping's newest submission
  def is_collected?
    is_collected
  end

  # Returns an array of the user_names for any TA's assigned to mark
  # this Grouping
  def get_ta_names
    ta_memberships.collect do |membership|
      membership.user.user_name
    end
  end

  # Returns true if this user has a pending status for this group;
  # false otherwise, or if user is not in this group.
  def pending?(user)
    membership_status(user) == StudentMembership::STATUSES[:pending]
  end

  # returns whether the user is the inviter of this group or not.
  def is_inviter?(user)
    membership_status(user) ==  StudentMembership::STATUSES[:inviter]
  end

  # invites each user in 'members' by its user name, to this group
  # If the method is invoked by an admin, checks on whether the students can
  # be part of the group are skipped.
  def invite(members,
             set_membership_status=StudentMembership::STATUSES[:pending],
             invoked_by_admin=false)
    # overloading invite() to accept members arg as both a string and a array
    members = [members] if !members.instance_of?(Array) # put a string in an
                                                 # array
    members.each do |m|
      next if m.blank? # ignore blank users
      m = m.strip
      user = User.where(user_name: m).first
      m_logger = MarkusLogger.instance
      if user
        if invoked_by_admin || self.can_invite?(user)
          member = self.add_member(user, set_membership_status)
          if member
            m_logger.log("Student invited '#{user.user_name}'.")
          else
            errors.add(:base, I18n.t('invite_student.fail.error',
                                     user_name: user.user_name))
            m_logger.log("Student failed to invite '#{user.user_name}'",
                         MarkusLogger::ERROR)
          end
        end
      else
        errors.add(:base, I18n.t('invite_student.fail.dne',
                                 user_name: m))
      end
    end
  end

  # Add a new member to base
 def add_member(user, set_membership_status=StudentMembership::STATUSES[:accepted])
    if user.has_accepted_grouping_for?(self.assignment_id) || user.hidden
      nil
    else
      member = StudentMembership.new(user: user, membership_status:
      set_membership_status, grouping: self)
      member.save
      # adjust repo permissions
      update_repository_permissions

      # remove any old deduction for this assignment
      remove_grace_period_deduction(member)

      # Add deductions for the new added member
      deduction = GracePeriodDeduction.new
      deduction.membership = member
      deduction.deduction = self.grace_period_deduction_single
      deduction.save

      member
    end
  end

  # define whether user can be invited in this grouping
  def can_invite?(user)
    m_logger = MarkusLogger.instance
    if user && user.student?
      if user.hidden
        errors.add(:base, I18n.t('invite_student.fail.hidden',
                                  user_name: user.user_name))
        m_logger.log("Student failed to invite '#{user.user_name}' (account has been " +
                     'disabled).', MarkusLogger::ERROR)

        return false
      end
      if self.inviter == user
        errors.add(:base, I18n.t('invite_student.fail.inviting_self',
                                  user_name: user.user_name))
        m_logger.log("Student failed to invite '#{user.user_name}'. Tried to invite " +
                     'himself.', MarkusLogger::ERROR)


      end
      if self.assignment.past_collection_date?
        errors.add(:base, I18n.t('invite_student.fail.due_date_passed',
                                  user_name: user.user_name))
        m_logger.log("Student failed to invite '#{user.user_name}'. Current time past " +
                     'collection date.', MarkusLogger::ERROR)

        return false
      end
      if self.student_membership_number >= self.assignment.group_max
        errors.add(:base, I18n.t('invite_student.fail.group_max_reached',
                                  user_name: user.user_name))
        m_logger.log("Student failed to invite '#{user.user_name}'. Group maximum" +
                     ' reached.', MarkusLogger::ERROR)
        return false
      end
      if self.assignment.section_groups_only &&
        user.section != self.inviter.section
        errors.add(:base, I18n.t('invite_student.fail.not_same_section',
                                  user_name: user.user_name))
        m_logger.log("Student failed to invite '#{user.user_name}'. Students not in" +
                     ' same section.', MarkusLogger::ERROR)

        return false
      end
      if user.has_accepted_grouping_for?(self.assignment.id)
        errors.add(:base, I18n.t('invite_student.fail.already_grouped',
                                  user_name: user.user_name))
        m_logger.log("Student failed to invite '#{user.user_name}'. Invitee already part" +
                     ' of another group.', MarkusLogger::ERROR)
        return false
      end
      if self.pending?(user)
        errors.add(:base, I18n.t('invite_student.fail.already_pending',
                                  user_name: user.user_name))
        m_logger.log("Student failed to invite '#{user.user_name}'. Invitee is already " +
                     ' pending member of this group.', MarkusLogger::ERROR)
        return false
      end
    else
      errors.add(:base, I18n.t('invite_student.fail.dne',
                                user_name: user.user_name))
      m_logger.log("Student failed to invite '#{user.user_name}'. Invitee does not " +
                   ' exist.', MarkusLogger::ERROR)
      return false
    end
    true
  end

  # Returns the status of this user, or nil if user is not a member
  def membership_status(user)
    member = student_memberships.where(user_id: user.id).first
    member ? member.membership_status : nil  # return nil if user is not a member
  end

  # returns the numbers of memberships, all includ (inviter, pending,
  # accepted
  def student_membership_number
     accepted_students.size + pending_students.size
  end

  # Returns true if either this Grouping has met the assignment group
  # size minimum, OR has been approved by an instructor
  def is_valid?
    admin_approved || (non_rejected_student_memberships.size >= assignment.group_min)
  end

  # Validates a group
  def validate_grouping
    self.admin_approved = true
    self.save
    # update repository permissions
    update_repository_permissions
  end

  # Strips admin_approved privledge
  def invalidate_grouping
    self.admin_approved = false
    self.save
    # update repository permissions
    update_repository_permissions
  end

  # Token Credit Query
  def give_tokens
    Token.create(grouping_id: self.id, tokens: self.assignment.tokens_per_day) if self.assignment.enable_test
  end

  # Grace Credit Query
  def available_grace_credits
    total = []
    accepted_students.each do |student|
      total.push(student.remaining_grace_credits)
    end
    total.min
  end

  # The grace credits deducted (of one student) for this specific submission
  # in the grouping
  def grace_period_deduction_single
    single = 0
    # Since for an instance of a grouping all members of the group will get
    # deducted the same amount (for a specific assignment), it is safe to pick
    # any deduction
    if !grace_period_deductions.nil? && !grace_period_deductions.first.nil?
      single = grace_period_deductions.first.deduction
    end
    single
  end

  # remove all deductions for this assignment for a particular member
  def remove_grace_period_deduction(membership)
    deductions = membership.user.grace_period_deductions
    deductions.each do |deduction|
      if deduction.membership.grouping.assignment.id == assignment.id
        membership.grace_period_deductions.delete(deduction)
        deduction.destroy
      end
    end
  end

  # Submission Functions
  def has_submission?
    #Return true if and only if this grouping has at least one submission
    #with attribute submission_version_used == true.
    !current_submission_used.nil?
  end

  def marking_completed?
    has_submission? && current_submission_used.get_latest_result.marking_state == Result::MARKING_STATES[:complete]
  end

  # EDIT METHODS
  # Removes the member by its membership id
  def remove_member(mbr_id)
    member = student_memberships.find(mbr_id)
    if member
      # Remove repository permissions first
      #   Corner case: members are removed by admins only.
      #   Hence, we do not require to check for validity of the group
      revoke_repository_permissions_for_membership(member)
      member.destroy
      if member.membership_status == StudentMembership::STATUSES[:inviter]
         if member.grouping.accepted_student_memberships.length > 0
            membership = member.grouping.accepted_student_memberships.first
            membership.membership_status = StudentMembership::STATUSES[:inviter]
            membership.save
         end
      end
    end
  end

  def delete_grouping
    self.student_memberships.all(include: :user).each do |member|
      member.destroy
    end
    # adjust repository permissions
    update_repository_permissions
    self.destroy
  end

  # Removes the member rejected by its membership id
  # Used as safeguard when student deletes the record
  def remove_rejected(mbr_id)
    member = memberships.find(mbr_id)
    member.destroy if member && member.membership_status == StudentMembership::STATUSES[:rejected]
  end

  def decline_invitation(student)
    membership = student.memberships.where(grouping_id: id).first
    membership.membership_status = StudentMembership::STATUSES[:rejected]
    membership.save
    # adjust repo permissions
    update_repository_permissions
  end

  # If a group is invalid OR valid and the user is the inviter of the group and
  # she is the _only_ member of this grouping it should be deletable
  # by this user, provided there haven't been any files submitted. Additionally,
  # the grace period for the assignment should not have passed.
  def deletable_by?(user)
    return false unless self.inviter == user
    (!self.is_valid?) || (self.is_valid? &&
                          self.accepted_students.size == 1 &&
                          self.number_of_submitted_files == 0 &&
                          self.assignment.group_assignment? &&
                          !assignment.past_collection_date?)
  end

  # Returns the number of files submitted by this grouping for a
  # particular assignment.
  def number_of_submitted_files
    path = '/'
    repo = self.group.repo
    rev = repo.get_latest_revision
    files = rev.files_at_path(File.join(File.join(self.assignment.repository_folder, path)))
    repo.close()
    files.keys.length
  end

  # Returns last modified date of the assignment_folder in this grouping's repository
  def assignment_folder_last_modified_date
    repo = self.group.repo
    rev = repo.get_latest_revision
    last_date = rev.timestamp

    repo.close()
    last_date
  end

  # Returns a list of missing assignment_files yet to be submitted
  def missing_assignment_files
    missing_assignment_files = []
    self.group.access_repo do |repo|
      rev = repo.get_latest_revision
      assignment = self.assignment
      assignment.assignment_files.each do |assignment_file|
        unless rev.path_exists?(File.join(assignment.repository_folder, assignment_file.filename))
          missing_assignment_files.push(assignment_file)
        end
      end
    end
    missing_assignment_files
  end

  def add_tas(tas)
    Grouping.assign_all_tas(id, Array(tas).map(&:id), assignment)
  end

  def remove_tas(ta_id_array)
    #if no tas to remove, return.
    return if ta_id_array == []
    ta_memberships_to_remove = ta_memberships.find_all_by_user_id(ta_id_array, include: :user)
    ta_memberships_to_remove.each do |ta_membership|
      ta_membership.destroy
      ta_memberships.delete(ta_membership)
    end
    criteria = self.all_assigned_criteria(self.tas - ta_memberships_to_remove.collect{|mem| mem.user})
    self.criteria_coverage_count = criteria.length
    self.save
  end

  def add_tas_by_user_name_array(ta_user_name_array)
    grouping_tas = []
    ta_user_name_array.each do |ta_user_name|
      ta = Ta.where(user_name: ta_user_name).first
      unless ta.nil?
        if ta_memberships.where(user_id: ta.id).first.nil?
          ta_memberships.create(user: ta)
        end
      end
      grouping_tas += Array(ta)
    end
    self.criteria_coverage_count = self.all_assigned_criteria(grouping_tas).length
    self.save
  end

  # Returns an array containing the group names that didn't exist
  def self.assign_tas_by_csv(csv_file_contents, assignment_id, encoding)
    failures = []
    csv_file_contents = csv_file_contents.utf8_encode(encoding)
    CSV.parse(csv_file_contents) do |row|
      group_name = row.shift # Knocks the first item from array
      group = Group.where(group_name: group_name).first
      if group.nil?
        failures.push(group_name)
      else
        grouping = group.grouping_for_assignment(assignment_id)
        if grouping.nil?
          failures.push(group_name)
        else
          grouping.add_tas_by_user_name_array(row) # The rest of the array
        end
      end
    end
    return failures
  end

  # Update repository permissions for students, if we allow external commits
  #   see: grant_repository_permissions and revoke_repository_permissions
  def update_repository_permissions
    # we do not need to do anything if we are not accepting external
    # command-line commits
    return unless self.write_repo_permissions?

    self.reload # VERY IMPORTANT! Make sure grouping object is not stale

    if self.is_valid?
      grant_repository_permissions
    else
      # grouping became invalid, remove repo permissions
      revoke_repository_permissions
    end
  end

  # When a Grouping is created, automatically create the folder for the
  # assignment in the repository, if it doesn't already exist.
  def create_grouping_repository_folder
    # create folder only if we are repo admin
    if self.group.repository_admin?
      self.group.access_repo do |repo|
        revision = repo.get_latest_revision
        assignment_folder = assignment.repository_folder

        if revision.path_exists?(assignment_folder)
          return true
        else
          txn = self.group.repo.get_transaction('markus')
          txn.add_path(assignment_folder)
          return self.group.repo.commit(txn)
        end
      end
    end
  end

  # Returns true, if and only if the configured repository setup
  # allows for externally accessible repositories, in which case
  # file submissions via the Web interface are not permitted. For
  # now, this works for Subversion repositories only.
  def repository_external_commits_only?
    assignment = self.assignment
    !assignment.allow_web_submits
  end

  # Should we write repository permissions for this grouping?
  def write_repo_permissions?
    MarkusConfigurator.markus_config_repository_admin? &&
        self.repository_external_commits_only?
  end

  def assigned_tas_for_criterion(criterion)
    if assignment.assign_graders_to_criteria
      tas.select do |ta|
        ta.criterion_ta_associations
          .where(criterion_id: criterion.id)
          .first
      end
    else
      []
    end
  end

  def all_assigned_criteria(ta_array)
    result = []
    if assignment.assign_graders_to_criteria
      ta_array.each do |ta|
        result = result.concat(ta.get_criterion_associations_by_assignment(assignment))
      end
    end
    result.map{|a| a.criterion}.uniq
  end

  # Get the section for this group. If assignment restricts member of a groupe
  # to a section, all students are in the same section. Therefore, return only
  # the inviters section
  def section
    if !self.inviter.nil? and self.inviter.has_section?
      return self.inviter.section.name
    end
    '-'
  end

  ##
  # Find the correct due date (section or not) and check if it is after
  # the last commit
  ##
  def past_due_date?

    timestamp = assignment_folder_last_modified_date
    due_dates = assignment.section_due_dates
    section = unless inviter.blank?
                inviter.section
              end
    section_due_date = unless section.blank? || due_dates.blank?
                         due_dates.where(section_id: section).first.due_date
                       end

    if !section_due_date.blank?
      timestamp > section_due_date
    else
      timestamp > assignment.due_date
    end
  end

  private

  # Once a grouping is valid, grant (write) repository permissions for students
  # who have accepted memberships (including the inviter)
  #
  # precondition: grouping is valid, self.reload has been called
  def grant_repository_permissions
    memberships = self.accepted_student_memberships
    unless memberships.instance_of?(Array)
      memberships = [memberships]
    end
    memberships.each do |member|
      # Add repository read and write permissions for user,
      # if we are required to do so
      if self.write_repo_permissions?
        begin
          self.group.access_repo do |repo|
            repo.add_user(member.user.user_name, Repository::Permission::READ_WRITE)
          end
        rescue Repository::UserAlreadyExistent
          # ignore case if user has permissions already
        end
      end
    end
  end

  # We need to revoke repository permissions for student users in certain cases.
  #
  # For instance if the inviter has invited 2 students for a total of 3 students in
  # that group, which in turn is the required group minimum. In that case, students
  # who have accepted their membership, would have gotten repo permissions granted.
  # But once one of the 2 invited students declines to be member of that group, the group
  # becomes invalid (is below the group minimum of 3 people), and, hence, granted
  # repo permissions for student users need to be revoked again.
  #
  # precondition: grouping is invalid, self.reload has been called
  def revoke_repository_permissions
    memberships = self.accepted_student_memberships
    unless memberships.instance_of?(Array)
      memberships = [memberships]
    end
    memberships.each do |member|
      # Revoke permissions for students
      if self.write_repo_permissions?
        self.group.access_repo do |repo|
          begin
            # the following throws a Repository::UserNotFound
            if repo.get_permissions(member.user.user_name) >= Repository::Permission::ANY
              # user has some permissions, we need to remove them
              repo.remove_user(member.user.user_name)
            end
          rescue Repository::UserNotFound
            # if student has no permissions, we are safe
          end
        end
      end
    end
  end

  # Removes repository permissions for a single StudentMembership object
  def revoke_repository_permissions_for_membership(student_membership)
    # Revoke permissions for student
    self.group.access_repo do |repo|
      if self.write_repo_permissions?
        begin
          # the following throws a Repository::UserNotFound
          if repo.get_permissions(student_membership.user.user_name) >= Repository::Permission::ANY
            # user has some permissions, we need to remove them
            repo.remove_user(student_membership.user.user_name)
          end
        rescue Repository::UserNotFound
          # if student has no permissions, we are safe
        end
      end
    end
  end

  # Removes any repository permissions of students for a to be destroyed
  # grouping object. see :before_destroy callback above
  def revoke_repository_permissions_for_students
    self.reload # avoid a stale object

    memberships = self.student_memberships # get any student memberships
    unless memberships.instance_of?(Array)
      memberships = [memberships]
    end
    memberships.each do |member|
      # Revoke permissions for students
      self.group.access_repo do |repo|
        if self.write_repo_permissions?
          begin
            # the following throws a Repository::UserNotFound
            if repo.get_permissions(member.user.user_name) >= Repository::Permission::ANY
              # user has some permissions, we need to remove them
              repo.remove_user(member.user.user_name)
            end
          rescue Repository::UserNotFound
            # if student has no permissions, we are safe
          end
        end
      end
    end
  end
end # end class Grouping
