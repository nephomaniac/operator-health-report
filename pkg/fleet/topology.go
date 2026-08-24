package fleet

import (
	"context"
	"fmt"
	"sort"
	"strings"

	sdk "github.com/openshift-online/ocm-sdk-go"
	fleetv1 "github.com/openshift-online/ocm-sdk-go/osdfleetmgmt/v1"
	"github.com/openshift/operator-health-report/pkg/logging"
)

// FleetCluster represents an MC or SC from the fleet management API
type FleetCluster struct {
	ClusterID    string `json:"cluster_id"`
	Name         string `json:"name"`
	Type         string `json:"type"`   // "management_cluster" or "service_cluster"
	Sector       string `json:"sector"`
	Region       string `json:"region"`
	Status       string `json:"status"`
	ParentSCName string `json:"parent_sc,omitempty"`
}

// Topology holds the complete HCP fleet topology
type Topology struct {
	MCs         []FleetCluster
	SCs         []FleetCluster
	BySector    map[string][]FleetCluster
	ByClusterID map[string]*FleetCluster
	ByName      map[string]*FleetCluster
}

// FetchTopology fetches the complete HCP fleet topology from the fleet management API.
// Makes 2 API calls: list management clusters and list service clusters.
// Returns nil topology (not an error) if the API is unavailable.
func FetchTopology(ctx context.Context, conn *sdk.Connection) (*Topology, error) {
	log := logging.Log

	t := &Topology{
		BySector:    map[string][]FleetCluster{},
		ByClusterID: map[string]*FleetCluster{},
		ByName:      map[string]*FleetCluster{},
	}

	// Fetch service clusters first (MCs reference them as parents)
	scResp, err := conn.OSDFleetMgmt().V1().ServiceClusters().List().
		Size(1000).
		SendContext(ctx)
	if err != nil {
		log.WithField("error", err).Debug("Fleet management API unavailable")
		return nil, nil
	}

	scByID := map[string]string{} // OSDFM resource ID → SC name
	scResp.Items().Each(func(sc *fleetv1.ServiceCluster) bool {
		clusterID := ""
		if ref, ok := sc.GetClusterManagementReference(); ok {
			clusterID, _ = ref.GetClusterId()
		}
		sector, _ := sc.GetSector()
		region, _ := sc.GetRegion()
		status, _ := sc.GetStatus()
		name, _ := sc.GetName()
		osdfmID, _ := sc.GetID()

		fc := FleetCluster{
			ClusterID: clusterID,
			Name:      name,
			Type:      "service_cluster",
			Sector:    sector,
			Region:    region,
			Status:    status,
		}
		t.SCs = append(t.SCs, fc)
		if osdfmID != "" {
			scByID[osdfmID] = name
		}

		return true
	})

	// Fetch management clusters
	mcResp, err := conn.OSDFleetMgmt().V1().ManagementClusters().List().
		Size(1000).
		SendContext(ctx)
	if err != nil {
		log.WithField("error", err).Debug("Fleet management MC list failed")
		return t, nil
	}

	mcResp.Items().Each(func(mc *fleetv1.ManagementCluster) bool {
		clusterID := ""
		if ref, ok := mc.GetClusterManagementReference(); ok {
			clusterID, _ = ref.GetClusterId()
		}
		sector, _ := mc.GetSector()
		region, _ := mc.GetRegion()
		status, _ := mc.GetStatus()
		name, _ := mc.GetName()

		parentSCName := ""
		if parent, ok := mc.GetParent(); ok {
			if parentID, ok := parent.GetClusterId(); ok {
				parentSCName = scByID[parentID]
			}
		}

		fc := FleetCluster{
			ClusterID:    clusterID,
			Name:         name,
			Type:         "management_cluster",
			Sector:       sector,
			Region:       region,
			Status:       status,
			ParentSCName: parentSCName,
		}
		t.MCs = append(t.MCs, fc)

		return true
	})

	// Build indexes
	all := append(t.MCs, t.SCs...)
	for i := range all {
		fc := &all[i]
		if fc.Sector != "" {
			t.BySector[fc.Sector] = append(t.BySector[fc.Sector], *fc)
		}
		if fc.ClusterID != "" {
			t.ByClusterID[fc.ClusterID] = fc
		}
		if fc.Name != "" {
			t.ByName[fc.Name] = fc
		}
	}

	log.WithField("mcs", len(t.MCs)).WithField("scs", len(t.SCs)).
		WithField("sectors", len(t.BySector)).Debug("Fleet topology loaded")

	return t, nil
}

// SectorClusters returns OCM cluster IDs for all MCs and SCs in the given sector.
func (t *Topology) SectorClusters(sector string) []string {
	if t == nil {
		return nil
	}
	var ids []string
	for _, fc := range t.BySector[sector] {
		if fc.ClusterID != "" {
			ids = append(ids, fc.ClusterID)
		}
	}
	return ids
}

// SectorClusterNames returns cluster names for all MCs and SCs in the given sector.
func (t *Topology) SectorClusterNames(sector string) []string {
	if t == nil {
		return nil
	}
	var names []string
	for _, fc := range t.BySector[sector] {
		if fc.Name != "" {
			names = append(names, fc.Name)
		}
	}
	return names
}

// EnrichCluster returns fleet metadata for a cluster, or nil if not found.
func (t *Topology) EnrichCluster(clusterID string) *FleetCluster {
	if t == nil {
		return nil
	}
	return t.ByClusterID[clusterID]
}

// EnrichByName returns fleet metadata by cluster name, or nil if not found.
func (t *Topology) EnrichByName(name string) *FleetCluster {
	if t == nil {
		return nil
	}
	return t.ByName[name]
}

// Sectors returns all known sector names, sorted.
func (t *Topology) Sectors() []string {
	if t == nil {
		return nil
	}
	var sectors []string
	for s := range t.BySector {
		sectors = append(sectors, s)
	}
	sort.Strings(sectors)
	return sectors
}

// String returns a human-readable summary of the topology.
func (t *Topology) String() string {
	if t == nil {
		return "no fleet topology"
	}
	sectors := t.Sectors()
	return fmt.Sprintf("%s (%d MCs, %d SCs)", strings.Join(sectors, ", "), len(t.MCs), len(t.SCs))
}
