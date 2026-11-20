from ansible.plugins.strategy.linear import StrategyModule as Linear

DOCUMENTATION = "name: retry_demo\nshort_description: retry failing tasks twice\n"


class StrategyModule(Linear):
    def run(self, iterator, play_context):
        for block in iterator._blocks:
            for task in getattr(block, "block", []):
                if not task.retries:
                    task.retries = 2
                    task.delay = 0
        return super().run(iterator, play_context)
