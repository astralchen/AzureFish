import AppLocalization
import AzureFishAPI
import AzureFishMoments
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

extension MomentsViewController {
    /// 连接列表动作与视图模型；渲染只更新页面内容和控件可用性。
    func bind() {
        viewModel.render = { [weak self] state in
            guard let self else { return }
            feedView.apply(state)
            navigationItem.rightBarButtonItem?.isEnabled = state.canCompose
            feedView.setNeedsLayout()
        }
        viewModel.didFinishRefresh = { [weak self] in self?.feedView.list.refreshControl?.endRefreshing() }
        feedView.refresh = { [weak self] in self?.viewModel.refresh() }
        feedView.retry = { [weak self] in self?.viewModel.retry() }
        feedView.loadNext = { [weak self] retry in self?.viewModel.refresh(next: true, retry: retry) }
        feedView.action = { [weak self] action, post in self?.action(action, post: post) }
        feedView.openCover = { [weak self] source in self?.coverMenu(source: source) }
    }
}
