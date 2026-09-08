# ==============================================================================
# ElastiCache Redis — pub/sub backbone for the /ws/live-odds gateway fan-out
# plus the live-odds read cache. Single primary (cluster mode disabled) keeps
# pub/sub ordering and PUBLISH fan-out simple; scale out replicas later.
# ==============================================================================

resource "aws_elasticache_subnet_group" "redis" {
  count      = var.create_redis ? 1 : 0
  name       = "mm-bet-${var.environment}-redis"
  subnet_ids = var.private_subnet_ids
}

resource "aws_elasticache_replication_group" "app" {
  count = var.create_redis ? 1 : 0

  replication_group_id = "mm-bet-${var.environment}-redis"
  description          = "Live odds pub/sub + cache"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  num_cache_clusters   = 1

  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.redis[0].name
  security_group_ids   = [aws_security_group.redis[0].id]

  port                       = 6379
  automatic_failover_enabled = false
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  snapshot_retention_limit   = 7
  snapshot_window            = "04:30-06:30"
}

