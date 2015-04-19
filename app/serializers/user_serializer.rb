
class UserSerializer < ActiveModel::Serializer
  attributes :id, :email, :name, :first_name, :last_name, :username, :nickname, :system_role, :receive_task_notifications, :receive_portfolio_notifications, :receive_feedback_notifications

	def system_role
		object.role.name if object.role
	end

end

class ShallowUserSerializer < ActiveModel::Serializer
  attributes :id, :name, :email
end
