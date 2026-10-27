package bo.edu.uagrm.saludu.notifications.application;

import java.util.List;

public record NotificationPage(boolean ok, List<Notification> data, Pagination pagination, long unreadCount) {
    public record Pagination(boolean hasMore, String nextCursor) {}
}
