import { Panel, Empty, LinkButton } from '../components/ui'

export function NotFound({ label = 'Page not found' }: { label?: string }) {
  return (
    <Panel title="404">
      <Empty title={label}>
        <div className="mt-3">
          <LinkButton to="/">Back to overview →</LinkButton>
        </div>
      </Empty>
    </Panel>
  )
}
