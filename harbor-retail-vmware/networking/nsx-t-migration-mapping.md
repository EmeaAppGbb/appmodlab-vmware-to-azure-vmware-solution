# NSX-V to NSX-T Migration Mapping

## Distributed Firewall Rules

| NSX-V Rule | NSX-T Equivalent | Notes |
|------------|------------------|-------|
| Allow-Web-to-App | DFW-Allow-Web-to-App | Migrate to Tier-1 Gateway firewall |
| Allow-App-to-DB | DFW-Allow-App-to-DB | Use distributed firewall |
| Block-Web-to-DB | DFW-Block-Web-to-DB | Implicit deny at end |

## Segments

| NSX-V Port Group | NSX-T Segment | Subnet | Gateway |
|------------------|---------------|--------|---------|
| Web-Segment (VLAN 10) | Web-Segment | 10.10.10.0/24 | 10.10.10.1 |
| App-Segment (VLAN 20) | App-Segment | 10.10.20.0/24 | 10.10.20.1 |
| DB-Segment (VLAN 30) | DB-Segment | 10.10.30.0/24 | 10.10.30.1 |

## Load Balancer

NSX-V Edge Load Balancer → NSX-T Load Balancer or Azure Load Balancer/Application Gateway

**Recommendation:** Use NSX-T Load Balancer for east-west, Azure Front Door for north-south traffic.
