# frozen_string_literal: true

module Appsignal
  class Hooks
    # @api private
    class ActiveJobHook < Appsignal::Hooks::Hook
      register :active_job

      def dependencies_present?
        defined?(::ActiveJob)
      end

      def install
        ::ActiveJob::Base
          .extend ::Appsignal::Hooks::ActiveJobHook::ActiveJobClassInstrumentation
      end

      module ActiveJobClassInstrumentation
        def execute(job)
          job_status = nil
          current_transaction = Appsignal::Transaction.current
          transaction =
            if current_transaction.nil_transaction?
              # No standalone integration started before ActiveJob integration.
              # We don't have a separate integration for this QueueAdapter like
              # we do for Sidekiq.
              #
              # Prefer job_id from provider, instead of ActiveJob's internal ID.
              Appsignal::Transaction.create(
                job["provider_job_id"] || job["job_id"],
                Appsignal::Transaction::BACKGROUND_JOB,
                Appsignal::Transaction::GenericRequest.new({})
              )
            else
              current_transaction
            end

          super
        rescue Exception => exception # rubocop:disable Lint/RescueException
          job_status = :failed
          transaction.set_error(exception)
          raise exception
        ensure
          tags = ActiveJobHelpers.tags_for_job(job)

          if transaction
            transaction.params =
              Appsignal::Utils::HashSanitizer.sanitize(
                job["arguments"],
                Appsignal.config[:filter_parameters]
              )

            transaction_tags = tags.dup
            transaction_tags["active_job_id"] = job["job_id"]
            provider_job_id = job["provider_job_id"]
            if provider_job_id
              transaction_tags[:provider_job_id] = provider_job_id
            end
            transaction.set_tags(transaction_tags)

            transaction.set_action_if_nil(ActiveJobHelpers.action_name(job))
            enqueued_at = job["enqueued_at"]
            if enqueued_at # Present in Rails 6 and up
              transaction.set_queue_start((Time.parse(enqueued_at).to_f * 1_000).to_i)
            end

            if current_transaction.nil_transaction?
              # Only complete transaction if ActiveJob is not wrapped in
              # another supported integration, such as Sidekiq.
              Appsignal::Transaction.complete_current!
            end
          end

          if job_status
            ActiveJobHelpers.increment_counter "queue_job_count", 1,
              tags.merge(:status => job_status)
          end
          ActiveJobHelpers.increment_counter "queue_job_count", 1,
            tags.merge(:status => :processed)
        end
      end

      module ActiveJobHelpers
        ACTION_MAILER_CLASSES = [
          "ActionMailer::DeliveryJob",
          "ActionMailer::Parameterized::DeliveryJob",
          "ActionMailer::MailDeliveryJob"
        ].freeze

        def self.action_name(job)
          case job["job_class"]
          when *ACTION_MAILER_CLASSES
            job["arguments"][0..1].join("#")
          else
            "#{job["job_class"]}#perform"
          end
        end

        def self.tags_for_job(job)
          tags = {}
          queue = job["queue_name"]
          tags[:queue] = queue if queue
          priority = job["priority"]
          tags[:priority] = priority if priority
          tags
        end

        def self.increment_counter(key, value, tags = {})
          Appsignal.increment_counter "active_job_#{key}", value, tags
        end
      end
    end
  end
end
