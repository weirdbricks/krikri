# TaskExecutor - Main entry point
# This file maintains backward compatibility by importing the refactored components
# 
# The implementation has been split into:
# - task_executor/executor.cr       - Main TaskExecutor class
# - task_executor/variable_context.cr - Variable context building
# - task_executor/result_display.cr  - Result display and formatting
# - task_executor/handler_runner.cr  - Handler notification and execution

require "./task_executor/executor"
require "./task_executor/variable_context"
require "./task_executor/result_display"
require "./task_executor/handler_runner"
